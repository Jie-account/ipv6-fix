[CmdletBinding()]
param(
    [ValidateSet('Check','Repair','Rollback')][string]$Mode = 'Check',
    [string]$JobDirectory,
    [string]$StateDirectory,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

function Write-Activity([string]$Message) {
    # 直接写标准输出，避免进度消息混入函数返回的数据。
    [Console]::WriteLine('PROGRESS|' + $Message)
}

function Test-Cancelled {
    if ($script:JobPath -and (Test-Path -LiteralPath (Join-Path $script:JobPath 'cancel.request'))) {
        throw [OperationCanceledException]::new('用户停止了本次操作。')
    }
}

function Save-Json([string]$Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 14
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($true))
}

function Get-Prefix([string]$Address, [int]$Length) {
    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    for ($bit = $Length; $bit -lt 128; $bit++) {
        $offset = [int][Math]::Floor($bit / 8)
        $bytes[$offset] = $bytes[$offset] -band (255 -bxor (1 -shl (7 - ($bit % 8))))
    }
    return ([Net.IPAddress]::new($bytes).ToString() + '/' + $Length)
}

function Test-PublicTarget([string]$Address) {
    $ip=[Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }
    $bytes=$ip.GetAddressBytes()
    # Mihomo 的 IPv6 fake-ip 位于基准测试段，不能用来验证物理网络。
    return (($bytes[0] -band 224) -eq 32 -and (Get-Prefix $Address 48) -ne '2001:2::/48' -and (Get-Prefix $Address 32) -ne '2001:db8::/32')
}

function Resolve-PublicTarget([string]$HostName) {
    # 仅在系统解析返回合成地址时使用独立 HTTPS DNS，不更改系统 DNS。
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    $reply=& $curl --noproxy '*' --ipv4 --silent --show-error --connect-timeout 3 --max-time 6 ('https://dns.alidns.com/resolve?name='+[Uri]::EscapeDataString($HostName)+'&type=AAAA') 2>$null
    if ($LASTEXITCODE -ne 0) { throw '独立 IPv6 目标解析失败。' }
    $data=($reply -join '') | ConvertFrom-Json
    $answer=$data.Answer | Where-Object {$_.type -eq 28 -and (Test-PublicTarget $_.data)} | Select-Object -First 1
    if (-not $answer) { throw '独立解析未返回可用于公网测试的 IPv6 地址。' }
    return [string]$answer.data
}

function Get-Targets {
    $definitions = @(
        @{Key='campus';Name='IPv6 HTTPS';Url='https://www.tsinghua.edu.cn/'},
        @{Key='probe';Name='IPv6 联网探测';Url='http://ipv6.msftconnecttest.com/connecttest.txt'}
    )
    foreach ($definition in $definitions) {
        Test-Cancelled
        $uri = [Uri]$definition.Url
        $target = [pscustomobject]@{Key=$definition.Key;Name=$definition.Name;Url=$definition.Url;HostName=$uri.DnsSafeHost;Port=$uri.Port;IPAddress='';SystemAddresses=@();Resolution='System';Error=''}
        try {
            $lookup = [Net.Dns]::GetHostAddressesAsync($uri.DnsSafeHost)
            if (-not $lookup.Wait(5000)) { throw '解析 IPv6 地址超时。' }
            $ipv6 = @($lookup.Result | Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and -not $_.IsIPv6LinkLocal})
            if ($ipv6.Count -eq 0) { throw '当前 DNS 未返回 IPv6 地址。' }
            $target.SystemAddresses=@($ipv6 | ForEach-Object {$_.ToString()})
            $real=$ipv6 | Where-Object {Test-PublicTarget $_.ToString()} | Select-Object -First 1
            if ($real) { $target.IPAddress=$real.ToString() }
            else { $target.Resolution='IndependentDns';$target.IPAddress=Resolve-PublicTarget $uri.DnsSafeHost }
        } catch { $target.Error = $_.Exception.Message }
        $target
    }
}

function Select-IPv6Adapter($Adapters,$Addresses,$Routes) {
    # 默认路径与公网地址所在接口分别记录，ULA-only TUN 不能遮蔽物理网卡。
    $ordered=@($Routes | Where-Object DestinationPrefix -eq '::/0' | Sort-Object @{Expression={[int]$_.RouteMetric + [int]$_.InterfaceMetric}})
    $active=@(foreach ($route in $ordered) {
        $Adapters | Where-Object {$_.ifIndex -eq $route.InterfaceIndex -and $_.Status -eq 'Up'} | Select-Object -First 1
    })
    $chosen=$active | Where-Object {
        $index=$_.ifIndex
        @($Addresses | Where-Object {$_.InterfaceIndex -eq $index -and (Test-PublicTarget $_.IPAddress.Split('%')[0]) -and $_.AddressState -in 'Preferred','Deprecated'}).Count -gt 0
    } | Select-Object -First 1
    if (-not $chosen) { $chosen=$active | Select-Object -First 1 }
    [pscustomobject]@{Chosen=$chosen;Default=($active | Select-Object -First 1)}
}

function Get-Inventory($Targets) {
    $adapters = @(Get-NetAdapter)
    $allAddresses = @(Get-NetIPAddress -AddressFamily IPv6)
    $allRoutes = @(Get-NetRoute -AddressFamily IPv6)
    $defaultRoutes = @($allRoutes | Where-Object DestinationPrefix -eq '::/0' | Sort-Object @{Expression={[int]$_.RouteMetric + [int]$_.InterfaceMetric}})
    $adapterSelection=Select-IPv6Adapter $adapters $allAddresses $allRoutes
    $chosen=$adapterSelection.Chosen
    if (-not $chosen) {
        return [pscustomobject]@{AdapterName='';AdapterGuid='';InterfaceIndex=0;DefaultAdapterName='';AlternatePath=$true;Addresses=@();Routes=@();DefaultSources=@{};Fingerprint='';Issue='没有可用的 IPv6 默认路由。'}
    }
    $routes = @($allRoutes | Where-Object InterfaceIndex -eq $chosen.ifIndex)
    $addresses = @(foreach ($address in $allAddresses | Where-Object InterfaceIndex -eq $chosen.ifIndex) {
        $parsed = [Net.IPAddress]::Parse($address.IPAddress.Split('%')[0])
        # 本工具处理可用于公网连接的 SLAAC 地址，不调整链路本地地址或 ULA。
        if (($parsed.GetAddressBytes()[0] -band 224) -ne 32) { continue }
        $prefix = Get-Prefix $parsed.ToString() $address.PrefixLength
        [pscustomobject]@{
            IPAddress=$parsed.ToString();Prefix=$prefix;PrefixLength=[int]$address.PrefixLength
            State=$address.AddressState.ToString();Origin=$address.PrefixOrigin.ToString();SkipAsSource=[bool]$address.SkipAsSource
            PreferredLifetimeSeconds=[double]$address.PreferredLifetime.TotalSeconds
            ValidLifetimeSeconds=[double]$address.ValidLifetime.TotalSeconds
            HasPrefixRoute=[bool](@($routes | Where-Object DestinationPrefix -eq $prefix).Count)
        }
    })
    $sources = @{}; $alternate=($adapterSelection.Default.ifIndex -ne $chosen.ifIndex -or -not $adapterSelection.Default.HardwareInterface)
    foreach ($target in $Targets | Where-Object IPAddress) {
        try {
            $selection = @(Find-NetRoute -RemoteIPAddress $target.IPAddress -ErrorAction Stop)
            if (@($selection | Where-Object {$_.IPAddress -and $_.InterfaceIndex -ne $chosen.ifIndex}).Count -gt 0) { $alternate=$true }
            $selected = $selection | Where-Object {$_.IPAddress -and $_.InterfaceIndex -eq $chosen.ifIndex} | Select-Object -First 1
            if ($selected) { $sources[$target.Key] = [Net.IPAddress]::Parse($selected.IPAddress.Split('%')[0]).ToString() }
        } catch { }
    }
    $addressKey = ($addresses | Sort-Object IPAddress | ForEach-Object {$_.IPAddress+'/'+$_.State+'/'+$_.SkipAsSource}) -join ';'
    $routeKey = ($routes | Where-Object {$_.DestinationPrefix -eq '::/0' -or $_.DestinationPrefix -like '*/64'} | Sort-Object DestinationPrefix | ForEach-Object {$_.DestinationPrefix+'/'+$_.NextHop}) -join ';'
    [pscustomobject]@{
        AdapterName=$chosen.Name;AdapterGuid=$chosen.InterfaceGuid.ToString();InterfaceIndex=[int]$chosen.ifIndex
        DefaultAdapterName=$adapterSelection.Default.Name
        AlternatePath=$alternate;DefaultRoutes=@($defaultRoutes | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,InterfaceMetric)
        Interfaces=@(foreach ($adapter in $adapters) {
            [pscustomobject]@{Name=$adapter.Name;InterfaceIndex=$adapter.ifIndex;HardwareInterface=$adapter.HardwareInterface;Status=$adapter.Status.ToString();Addresses=@($allAddresses | Where-Object InterfaceIndex -eq $adapter.ifIndex | Select-Object IPAddress,AddressState,PrefixOrigin,SkipAsSource,PreferredLifetime,ValidLifetime)}
        })
        Addresses=$addresses;Routes=@($routes | Select-Object DestinationPrefix,NextHop,RouteMetric)
        DefaultSources=$sources;Fingerprint=($chosen.InterfaceGuid.ToString()+'|'+$addressKey+'|'+$routeKey+'|'+(($defaultRoutes | ForEach-Object {$_.InterfaceIndex.ToString()+'/'+$_.NextHop+'/'+$_.RouteMetric+'/'+$_.InterfaceMetric}) -join ';'));Issue=''
    }
}

function New-ProbeRequest($Target, [string]$SourceAddress, [int]$Round) {
    [pscustomobject]@{Target=$Target;SourceAddress=$SourceAddress;Round=$Round}
}

function Invoke-ProbeBatch($Requests) {
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($request in $Requests) { $queue.Enqueue($request) }
    $running = [Collections.Generic.List[object]]::new()
    $results = [Collections.Generic.List[object]]::new()
    $total = $queue.Count
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { throw '系统缺少 curl.exe，无法进行逐源地址验证。' }
    try {
        while ($queue.Count -gt 0 -or $running.Count -gt 0) {
            Test-Cancelled
            while ($queue.Count -gt 0 -and $running.Count -lt 4) {
                $request = $queue.Dequeue()
                $target = $request.Target
                $arguments = @('--noproxy','*','--ipv6','--head','--silent','--show-error','--output','NUL','--connect-timeout','3','--max-time','5',
                    '--resolve',($target.HostName+':'+$target.Port+':['+$target.IPAddress+']'),
                    '--write-out','HTTP=%{http_code};LOCAL=%{local_ip};REMOTE=%{remote_ip};CONNECT=%{time_connect}')
                if ($request.SourceAddress) { $arguments += @('--interface',$request.SourceAddress) }
                $arguments += $target.Url
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName=$curl
                $startInfo.Arguments=($arguments | ForEach-Object {'"'+$_.Replace('"','\"')+'"'}) -join ' '
                $startInfo.UseShellExecute=$false; $startInfo.CreateNoWindow=$true
                $startInfo.RedirectStandardOutput=$true; $startInfo.RedirectStandardError=$true
                $startInfo.StandardOutputEncoding=[Text.Encoding]::UTF8; $startInfo.StandardErrorEncoding=[Text.Encoding]::UTF8
                $probeProcess=[Diagnostics.Process]::new(); $probeProcess.StartInfo=$startInfo
                [void]$probeProcess.Start()
                $running.Add([pscustomobject]@{Request=$request;Process=$probeProcess;Output=$probeProcess.StandardOutput.ReadToEndAsync();Error=$probeProcess.StandardError.ReadToEndAsync();Started=[DateTime]::UtcNow})
            }
            for ($index=$running.Count-1; $index -ge 0; $index--) {
                $item=$running[$index]
                $timedOut=([DateTime]::UtcNow-$item.Started).TotalSeconds -gt 8
                if (-not $item.Process.HasExited -and -not $timedOut) { continue }
                if ($timedOut -and -not $item.Process.HasExited) { $item.Process.Kill() }
                [void]$item.Process.WaitForExit(1500)
                $output=$item.Output.GetAwaiter().GetResult().Trim()
                $errorText=$item.Error.GetAwaiter().GetResult().Trim()
                $exitCode=$item.Process.ExitCode
                if ($timedOut) { $exitCode=28 }
                $http=0; $local=''; $remote=''
                if ($output -match 'HTTP=(\d+)') { $http=[int]$matches[1] }
                if ($output -match 'LOCAL=([^;]*)') { $local=$matches[1] }
                if ($output -match 'REMOTE=([^;]*)') { $remote=$matches[1] }
                $classification='OtherFailure'
                if ($exitCode -eq 0 -and $http -ge 100 -and $http -le 599) { $classification='Reachable' }
                elseif ($exitCode -in 7,28) { $classification='NetworkFailure' }
                $results.Add([pscustomobject]@{
                    Time=(Get-Date).ToString('o');TargetKey=$item.Request.Target.Key;TargetName=$item.Request.Target.Name
                    TargetIP=$item.Request.Target.IPAddress;SourceAddress=$item.Request.SourceAddress;Round=$item.Request.Round
                    ExitCode=$exitCode;HttpStatus=$http;LocalAddress=$local;RemoteAddress=$remote;Classification=$classification;Error=$errorText
                })
                $item.Process.Dispose(); $running.RemoveAt($index)
                Write-Activity ('连接验证 '+$results.Count+'/'+$total)
            }
            if ($running.Count -gt 0) { Start-Sleep -Milliseconds 80 }
        }
    } finally {
        foreach ($item in $running) {
            try { if (-not $item.Process.HasExited) { $item.Process.Kill() } } catch { }
            $item.Process.Dispose()
        }
    }
    return $results.ToArray()
}

function Test-ProbePair($Probes,[string]$TargetKey,[string]$Source,[string]$Classification) {
    foreach ($round in 1..2) {
        $matching=@($Probes | Where-Object {$_.TargetKey -eq $TargetKey -and $_.SourceAddress -eq $Source -and $_.Round -eq $round -and $_.Classification -eq $Classification})
        if ($matching.Count -eq 0) { return $false }
    }
    return $true
}

function Get-PathAssessment($Inventory,$Targets,$Probes) {
    # 健康判定覆盖所有已解析目标；绑定成功还需核对实际本地地址。
    $defaultOk=$true; $nativeOk=$true
    foreach ($target in $Targets) {
        if (@($Probes | Where-Object {$_.TargetKey -eq $target.Key -and -not $_.SourceAddress -and $_.Classification -eq 'Reachable'}).Count -eq 0) { $defaultOk=$false }
        if (@($Probes | Where-Object {$_.TargetKey -eq $target.Key -and $_.SourceAddress -and $_.LocalAddress -eq $_.SourceAddress -and $_.Classification -eq 'Reachable'}).Count -eq 0) { $nativeOk=$false }
    }
    $context='默认路径：'+$Inventory.DefaultAdapterName+'；公网地址检查：'+$Inventory.AdapterName+'。'
    if ($defaultOk -and $nativeOk) {
        return [pscustomobject]@{Status='Healthy';Title='默认路径与源地址检查通过';Summary=($context+'两个路径均可访问真实 IPv6 目标。TUN 开启时，绑定源地址仍不能完全排除流量被接管。未修改设置。')}
    }
    if ($defaultOk) {
        return [pscustomobject]@{Status='Inconclusive';Title='默认路径可用，原生 IPv6 尚未验证';Summary=($context+'默认访问成功，公网源地址测试未全部通过。请临时退出 TUN 后复查，以区分代理与接入网络问题。未修改设置。')}
    }
    if ($nativeOk) {
        return [pscustomobject]@{Status='Inconclusive';Title='源地址可达，默认路径异常';Summary=($context+'绑定公网源地址成功，默认连接失败。请检查 TUN 路由或代理状态。未修改地址选择设置。')}
    }
    return [pscustomobject]@{Status='Inconclusive';Title='IPv6 连接异常，尚未确定原因';Summary=($context+'默认路径与源地址测试未全部通过；当前证据不足以修改地址。请查看记录，并在退出 TUN 后对照检查。')}
}

function Get-RepairPlan($Inventory,$Targets,$Probes) {
    # 只有同一固定目标的重复对照成立，才提出失效旧源地址的排除计划。
    if ($Inventory.AlternatePath) {
        return [pscustomobject]@{CanRepair=$false;WorkingAddress='';TargetKey='';ExcludeAddresses=@();Reason='默认路径涉及虚拟或其他网卡，需先区分原生通路与代理通路。'}
    }
    $candidates=@($Inventory.Addresses | Where-Object {$_.State -eq 'Preferred' -and -not $_.SkipAsSource -and $_.Origin -eq 'RouterAdvertisement'})
    foreach ($target in $Targets | Where-Object IPAddress) {
        if (-not (Test-ProbePair $Probes $target.Key '' 'NetworkFailure')) { continue }
        $working=@($candidates | Where-Object {Test-ProbePair $Probes $target.Key $_.IPAddress 'Reachable'} | Sort-Object @{Expression='HasPrefixRoute';Descending=$true},@{Expression='PreferredLifetimeSeconds';Descending=$true})
        foreach ($good in $working) {
            $bad=@($candidates | Where-Object {
                $_.Prefix -ne $good.Prefix -and
                ($_.PreferredLifetimeSeconds -le $good.PreferredLifetimeSeconds -or (-not $_.HasPrefixRoute -and $good.HasPrefixRoute)) -and
                (Test-ProbePair $Probes $target.Key $_.IPAddress 'NetworkFailure')
            })
            if ($bad.Count -eq 0) { continue }
            $selected=$Inventory.DefaultSources[$target.Key]
            if (-not $selected -or $selected -notin @($bad.IPAddress)) { continue }
            return [pscustomobject]@{CanRepair=$true;WorkingAddress=$good.IPAddress;TargetKey=$target.Key;ExcludeAddresses=@($bad.IPAddress);Reason='重复对照证实旧前缀源地址失败，而另一前缀源地址可用。'}
        }
    }
    return [pscustomobject]@{CanRepair=$false;WorkingAddress='';TargetKey='';ExcludeAddresses=@();Reason='没有形成足以自动修复的旧源地址对照证据。'}
}

function Get-AddressRecord([string]$AdapterGuid,[string]$Address) {
    $adapter=Get-NetAdapter | Where-Object { $_.InterfaceGuid.ToString() -eq $AdapterGuid } | Select-Object -First 1
    if (-not $adapter) { return $null }
    return Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Address -ErrorAction SilentlyContinue
}

function Set-AddressSelection([string]$AdapterGuid,[string]$Address,[bool]$Skip) {
    $record=Get-AddressRecord $AdapterGuid $Address
    if (-not $record) { throw ('地址已经变化：'+$Address) }
    Set-NetIPAddress -InputObject $record -SkipAsSource $Skip -ErrorAction Stop
    $actual=Get-AddressRecord $AdapterGuid $Address
    if (-not $actual -or [bool]$actual.SkipAsSource -ne $Skip) { throw ('地址设置验证失败：'+$Address) }
}

function Restore-Transaction($Transaction,[string]$Path) {
    $errors=[Collections.Generic.List[string]]::new()
    $restored=0; $expired=0
    foreach ($change in $Transaction.Changes) {
        try {
            $record=Get-AddressRecord $change.AdapterGuid $change.IPAddress
            if (-not $record) { $expired++; continue }
            if ([bool]$record.SkipAsSource -ne [bool]$change.Before) {
                Set-AddressSelection $change.AdapterGuid $change.IPAddress ([bool]$change.Before)
                $restored++
            }
        } catch { $errors.Add($_.Exception.Message) }
    }
    if ($errors.Count -eq 0) { $Transaction.Status='RolledBack' } else { $Transaction.Status='RollbackIncomplete' }
    $Transaction.UpdatedAt=(Get-Date).ToString('o')
    Save-Json $Path $Transaction
    return [pscustomobject]@{Success=($errors.Count -eq 0);Restored=$restored;Expired=$expired;Errors=$errors.ToArray()}
}

function Invoke-RepairPlan($Inventory,$Plan,[string]$TransactionPath,[scriptblock]$Verify) {
    $changes=@(foreach ($ip in $Plan.ExcludeAddresses) {
        $original=$Inventory.Addresses | Where-Object IPAddress -eq $ip | Select-Object -First 1
        if (-not $original -or $original.SkipAsSource) { throw '计划中的地址状态已变化。' }
        [pscustomobject]@{AdapterGuid=$Inventory.AdapterGuid;IPAddress=$ip;Before=[bool]$original.SkipAsSource;After=$true}
    })
    if ($changes.Count -eq 0) { throw '没有可以应用的地址修改。' }
    $transaction=[pscustomobject]@{SchemaVersion=1;CreatedAt=(Get-Date).ToString('o');UpdatedAt=(Get-Date).ToString('o');Status='Prepared';WorkingAddress=$Plan.WorkingAddress;Changes=$changes}
    Save-Json $TransactionPath $transaction
    try {
        foreach ($change in $changes) {
            Test-Cancelled
            Write-Activity ('排除已证实失效的旧地址 '+$change.IPAddress)
            Set-AddressSelection $change.AdapterGuid $change.IPAddress $true
        }
        Test-Cancelled
        $transaction.Status='Applied'; Save-Json $TransactionPath $transaction
        $verified=& $Verify
        if (-not $verified) { throw '修改后的默认连接复测未通过。' }
        $transaction.Status='Verified'; $transaction.UpdatedAt=(Get-Date).ToString('o'); Save-Json $TransactionPath $transaction
        return [pscustomobject]@{Success=$true;Cancelled=$false;Changes=$changes;Error='';Rollback=$null}
    } catch {
        $failure=$_.Exception.Message
        $wasCancelled=$_.Exception -is [OperationCanceledException]
        $rollback=Restore-Transaction $transaction $TransactionPath
        return [pscustomobject]@{Success=$false;Cancelled=$wasCancelled;Changes=$changes;Error=$failure;Rollback=$rollback}
    }
}

function Get-LastTransaction([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending) {
        try {
            $data=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data.SchemaVersion -eq 1 -and $data.Status -ne 'RolledBack' -and @($data.Changes).Count -gt 0) {
                return [pscustomobject]@{Path=$file.FullName;Data=$data}
            }
        } catch { }
    }
    return $null
}

function Get-AddressViews($Inventory,$Probes) {
    foreach ($address in $Inventory.Addresses) {
        $own=@($Probes | Where-Object SourceAddress -eq $address.IPAddress)
        $reachable=@($own | Where-Object Classification -eq 'Reachable').Count
        $failed=@($own | Where-Object Classification -eq 'NetworkFailure').Count
        $text='未单独探测'
        if ($address.SkipAsSource) { $text='已排除自动选择' }
        elseif ($reachable -gt 0 -and $failed -gt 0) { $text='部分可达' }
        elseif ($reachable -gt 0) { $text='可用' }
        elseif ($failed -gt 0) { $text='连续连接失败' }
        elseif (@($Probes | Where-Object {$_.SourceAddress -eq '' -and $_.LocalAddress -eq $address.IPAddress -and $_.Classification -eq 'Reachable'}).Count -gt 0) { $text='默认连接已验证' }
        [pscustomobject]@{AdapterName=$Inventory.AdapterName;IPAddress=$address.IPAddress;State=$address.State;SkipAsSource=$address.SkipAsSource;ProbeStatus=$text}
    }
}

if ($LibraryOnly) { return }

[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$script:JobPath=[IO.Path]::GetFullPath($JobDirectory)
New-Item -ItemType Directory -Path $script:JobPath -Force | Out-Null
$statePath=[IO.Path]::GetFullPath($StateDirectory)
$transactionDirectory=Join-Path $statePath 'transactions'
New-Item -ItemType Directory -Path $transactionDirectory -Force | Out-Null
$startedAt=Get-Date
$report=[ordered]@{Version=1;Mode=$Mode;StartedAt=$startedAt.ToString('o');CompletedAt='';Status='Error';Title='检查未完成';Summary='';AdapterName='';AdapterGuid='';LogDirectory=$script:JobPath;Addresses=@();Probes=@();Changes=@();TransactionFile='';CanUndo=$false;Error=''}
$inventory=$null; $probes=@(); $targets=@()
try {
    Test-Cancelled
    if ($Mode -eq 'Rollback') {
        $last=Get-LastTransaction $transactionDirectory
        if (-not $last) { $report.Status='NoChanges';$report.Title='没有需要恢复的修改';$report.Summary='尚无本工具保存的未恢复修改。' }
        else {
            Write-Activity '正在恢复上次修改的原值'
            $result=Restore-Transaction $last.Data $last.Path
            $report.TransactionFile=$last.Path
            if ($result.Success) {
                $report.Status='RolledBack';$report.Title='已恢复上次修改'
                $report.Summary='已恢复 '+$result.Restored+' 个地址的原值；'+$result.Expired+' 个地址已自然消失。恢复原值可能再次使用原先失效的旧地址。'
            } else { $report.Status='RollbackPartial';$report.Title='部分设置未恢复';$report.Summary=$result.Errors -join '；' }
        }
    } else {
        Write-Activity '正在读取 IPv6 地址与默认路由'
        $targets=@(Get-Targets)
        $available=@($targets | Where-Object IPAddress)
        $inventory=Get-Inventory $available
        $report.AdapterName=$inventory.AdapterName;$report.AdapterGuid=$inventory.AdapterGuid
        Save-Json (Join-Path $script:JobPath 'before.json') $inventory
        Save-Json (Join-Path $script:JobPath 'targets.json') $targets
        if ($available.Count -eq 0) {
            $report.Status='Inconclusive';$report.Title='暂时无法完成检查';$report.Summary='测试目标的 IPv6 地址未能解析，未修改网络设置。'
        } else {
            Write-Activity '正在验证系统默认 IPv6 连接'
            $defaultRequests=@(foreach ($target in $available) { New-ProbeRequest $target '' 1 })
            $probes=@(Invoke-ProbeBatch $defaultRequests)
            if ($inventory.AlternatePath -or $inventory.Addresses.Count -eq 0) {
                Write-Activity ('默认路径：'+$inventory.DefaultAdapterName+'；正在检查 '+$inventory.AdapterName+' 公网源地址')
                $eligible=@($inventory.Addresses | Where-Object {$_.State -eq 'Preferred' -and -not $_.SkipAsSource})
                if ($eligible.Count -gt 12) { throw '可选 IPv6 地址超过 12 个，请查看记录后进一步诊断。' }
                $requests=@(foreach ($address in $eligible) { foreach ($target in $available) { New-ProbeRequest $target $address.IPAddress 1 } })
                $probes+=@(Invoke-ProbeBatch $requests)
                $assessment=Get-PathAssessment $inventory $available $probes
                $report.Status=$assessment.Status;$report.Title=$assessment.Title;$report.Summary=$assessment.Summary
            } elseif (@($probes | Where-Object Classification -ne 'Reachable').Count -eq 0) {
                $report.Status='Healthy';$report.Title='当前 IPv6 连接正常';$report.Summary='默认 IPv6 访问已通过测试，无需修改地址选择设置。'
            } else {
                $eligible=@($inventory.Addresses | Where-Object {$_.State -eq 'Preferred' -and -not $_.SkipAsSource -and $_.Origin -eq 'RouterAdvertisement'})
                if ($eligible.Count -gt 12) { throw '可选 IPv6 地址超过 12 个，请查看记录后进一步诊断。' }
                Write-Activity '正在逐个比较 IPv6 源地址，请稍候'
                $requests=@(foreach ($target in $available) { New-ProbeRequest $target '' 2 }
                    foreach ($round in 1..2) { foreach ($address in $eligible) { foreach ($target in $available) { New-ProbeRequest $target $address.IPAddress $round } } })
                $probes+=@(Invoke-ProbeBatch $requests)
                $plan=Get-RepairPlan $inventory $available $probes
                Save-Json (Join-Path $script:JobPath 'plan.json') $plan
                if (-not $plan.CanRepair) {
                    $report.Status='Inconclusive';$report.Title='未确认旧源地址故障';$report.Summary='部分测试未通过，但没有形成可用新地址与失效旧地址的重复对照证据，未修改设置。'
                } elseif ($Mode -eq 'Check') {
                    $report.Status='NeedsRepair';$report.Title='发现可修复的旧源地址问题';$report.Summary='已确认 '+$plan.ExcludeAddresses.Count+' 个失效旧源地址。点击“检查并修复”可重新核验后处理。'
                } else {
                    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
                    if (-not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '修复需要管理员权限，请通过客户端重新打开。' }
                    $latest=Get-Inventory $available
                    if ($latest.Fingerprint -ne $inventory.Fingerprint) { throw '检查期间网络地址或路由发生变化，本次保持原状；请再检查一次。' }
                    $target=$available | Where-Object Key -eq $plan.TargetKey | Select-Object -First 1
                    Write-Activity '正在复核可用地址与当前故障'
                    $guard=@(Invoke-ProbeBatch @((New-ProbeRequest $target '' 3),(New-ProbeRequest $target $plan.WorkingAddress 3)))
                    $probes+=$guard
                    if (@($guard | Where-Object {$_.SourceAddress -eq '' -and $_.Classification -eq 'Reachable'}).Count -gt 0) {
                        $report.Status='Healthy';$report.Title='IPv6 已自行恢复';$report.Summary='修改前的复核已通过，本次未修改设置。'
                    } elseif (@($guard | Where-Object {$_.SourceAddress -eq $plan.WorkingAddress -and $_.Classification -eq 'Reachable'}).Count -eq 0) {
                        $report.Status='Inconclusive';$report.Title='网络状态正在变化';$report.Summary='原先可用的源地址也未通过复核，本次保持原状。'
                    } else {
                        $beforeWrite=Get-Inventory $available
                        if ($beforeWrite.Fingerprint -ne $inventory.Fingerprint) { throw '准备修复时网络状态已变化，本次保持原状；请重新检查。' }
                        $transactionPath=Join-Path $transactionDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')+'.json')
                        $report.TransactionFile=$transactionPath
                        $verify={
                            Write-Activity '设置已应用，正在复测默认 IPv6 连接'
                            $verification=@(Invoke-ProbeBatch @((New-ProbeRequest $target '' 1),(New-ProbeRequest $target '' 2)))
                            Save-Json (Join-Path $script:JobPath 'verification.json') $verification
                            return (@($verification | Where-Object {$_.Classification -eq 'Reachable' -and $_.LocalAddress -and $_.LocalAddress -notin $plan.ExcludeAddresses}).Count -eq 2)
                        }
                        $applied=Invoke-RepairPlan $inventory $plan $transactionPath $verify
                        if ($applied.Success) {
                            $report.Status='Repaired';$report.Title='IPv6 已恢复';$report.Changes=$applied.Changes
                            $report.Summary='已避开 '+$applied.Changes.Count+' 个失效旧源地址，默认连接复测通过。地址和默认路由保持，未重启网卡。'
                        } else {
                            $report.Status='RepairFailed';$report.Title='修复复测未通过';$report.Error=$applied.Error
                            if ($applied.Rollback.Success -and $applied.Cancelled) { $report.Status='Cancelled';$report.Title='本次操作已停止';$report.Summary='本次修改已全部还原，诊断记录已保存。' }
                            elseif ($applied.Rollback.Success) { $report.Summary='本次修改已还原，诊断记录已保存。' }
                            else { $report.Status='RollbackPartial';$report.Title='需要检查部分修改';$report.Summary='自动还原未全部成功，请查看记录：'+($applied.Rollback.Errors -join '；') }
                        }
                    }
                }
            }
        }
    }
} catch [OperationCanceledException] {
    $report.Status='Cancelled';$report.Title='本次操作已停止';$report.Summary='已停止检查；如已开始修改，已尝试恢复本次原值，请查看记录。'
} catch {
    $report.Status='Error';$report.Title='本次操作未完成';$report.Summary=$_.Exception.Message;$report.Error=$_.ToString()
} finally {
    if ($targets.Count -gt 0 -and @($targets | Where-Object {-not $_.IPAddress}).Count -gt 0 -and $report.Status -eq 'Healthy') {
        $report.Status='Inconclusive';$report.Title='部分 IPv6 测试通过';$report.Summary+=' 部分目标解析失败，完整连接状态尚未验证。'
    }
    if ($inventory) {
        try { $finalInventory=Get-Inventory $targets;Save-Json (Join-Path $script:JobPath 'after.json') $finalInventory;$report.Addresses=@(Get-AddressViews $finalInventory $probes) }
        catch { $report.Addresses=@(Get-AddressViews $inventory $probes) }
    }
    $report.Probes=@($probes)
    $report.CompletedAt=(Get-Date).ToString('o')
    $report.CanUndo=[bool](Get-LastTransaction $transactionDirectory)
    Save-Json (Join-Path $script:JobPath 'result.json') $report
    $summary=@('IPv6 连接修复工具',$report.CompletedAt,$report.Title,$report.Summary,'网卡：'+$report.AdapterName,'记录：'+$script:JobPath)
    [IO.File]::WriteAllLines((Join-Path $script:JobPath 'result.txt'),[string[]]$summary,[Text.UTF8Encoding]::new($true))
    Write-Activity $report.Title
}
