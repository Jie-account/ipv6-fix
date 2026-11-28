[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference='Stop'
if(-not $ProjectRoot){$ProjectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $ProjectRoot 'client\src\NetworkEngine.ps1') -LibraryOnly
$testRoot=Join-Path $ProjectRoot ('client\test-results\core-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$script:JobPath=$testRoot
$results=[Collections.Generic.List[object]]::new()

function Assert-True($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Run-Test([string]$Name,[scriptblock]$Body) {
    try { & $Body; $results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''});Write-Host ('PASS '+$Name) }
    catch { $results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message) }
}

function New-Case {
    # 使用原故障结构的脱敏样例，测试不依赖个人抓包，也不创建真实 IP。
    $record=Get-Content -LiteralPath (Join-Path $ProjectRoot 'client\tests\fixtures\stale-prefix.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $addresses=@(foreach($address in $record.Addresses | Where-Object IPAddress -notlike 'fe80*') {
        $prefix=Get-Prefix $address.IPAddress 64
        [pscustomobject]@{IPAddress=$address.IPAddress;Prefix=$prefix;State='Preferred';Origin='RouterAdvertisement';SkipAsSource=$false;PreferredLifetimeSeconds=$address.PreferredLifetime.TotalSeconds;HasPrefixRoute=[bool](@($record.Routes | Where-Object DestinationPrefix -eq $prefix).Count)}
    })
    $good=$addresses | Sort-Object PreferredLifetimeSeconds -Descending | Select-Object -First 1
    $old=$addresses | Where-Object IPAddress -ne $good.IPAddress | Select-Object -First 1
    $inventory=[pscustomobject]@{AdapterName='WLAN';AdapterGuid='{00000000-0000-4000-8000-000000000001}';Addresses=$addresses;DefaultSources=@{campus=$old.IPAddress}}
    $targets=@([pscustomobject]@{Key='campus';IPAddress='2001:db8:ffff::80'})
    $probes=@(foreach($round in 1..2) {
        [pscustomobject]@{TargetKey='campus';SourceAddress='';Round=$round;Classification='NetworkFailure'}
        foreach($address in $addresses) {
            $classification='NetworkFailure';if($address.IPAddress -eq $good.IPAddress){$classification='Reachable'}
            [pscustomobject]@{TargetKey='campus';SourceAddress=$address.IPAddress;Round=$round;Classification=$classification}
        }
    })
    [pscustomobject]@{Inventory=$inventory;Targets=$targets;Probes=$probes;Good=$good.IPAddress}
}

Run-Test '实际故障回放：识别两个失效旧前缀地址' {
    $case=New-Case;$plan=Get-RepairPlan $case.Inventory $case.Targets $case.Probes
    Assert-True $plan.CanRepair '没有识别出实际故障'
    Assert-True ($plan.ExcludeAddresses.Count -eq 2) '应只排除两个旧地址'
    Assert-True ($plan.WorkingAddress -eq $case.Good) '选错可用地址'
}
Run-Test '默认连接健康时不修复' {
    $case=New-Case;$case.Probes | Where-Object SourceAddress -eq '' | ForEach-Object {$_.Classification='Reachable'}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '健康连接被误判'
}
Run-Test '所有源地址失败时不排除地址' {
    $case=New-Case;$case.Probes | ForEach-Object {$_.Classification='NetworkFailure'}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '没有可用地址也提出了修复'
}
Run-Test '单轮失败不足以自动修复' {
    $case=New-Case;$case.Probes | Where-Object {$_.Round -eq 2 -and $_.Classification -eq 'NetworkFailure'} | ForEach-Object {$_.Classification='Reachable'}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '短暂波动被当成持续故障'
}
Run-Test 'TLS等其他错误不当作失效源地址' {
    $case=New-Case;$case.Probes | Where-Object {$_.SourceAddress -and $_.Classification -eq 'NetworkFailure'} | ForEach-Object {$_.Classification='OtherFailure'}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '非连接错误被误修复'
}
Run-Test '同一前缀问题不套用旧前缀修复' {
    $case=New-Case;$prefix=($case.Inventory.Addresses | Where-Object IPAddress -eq $case.Good).Prefix
    $case.Inventory.Addresses | ForEach-Object {$_.Prefix=$prefix}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '不同类型的问题被套用修复'
}
Run-Test '已知默认选择不是失效源时不修复' {
    $case=New-Case;$case.Inventory.DefaultSources.campus=$case.Good
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '对照与默认选择矛盾仍提出修复'
}
Run-Test '已排除的地址保持原状' {
    $case=New-Case;$case.Inventory.Addresses | Where-Object IPAddress -ne $case.Good | ForEach-Object {$_.SkipAsSource=$true}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '重复调整已排除地址'
}

# 多网卡与合成 DNS 场景仅使用内存模型，不调用真实网卡。
function New-AdapterCase {
    [pscustomobject]@{
        Adapters=@([pscustomobject]@{Name='测试隧道';ifIndex=8;Status='Up';HardwareInterface=$false},[pscustomobject]@{Name='无线网络';ifIndex=9;Status='Up';HardwareInterface=$true})
        Addresses=@([pscustomobject]@{InterfaceIndex=8;IPAddress='fd00::1';AddressState='Preferred'},[pscustomobject]@{InterfaceIndex=9;IPAddress='2001:db8::1';AddressState='Preferred'})
        Routes=@([pscustomobject]@{InterfaceIndex=8;DestinationPrefix='::/0';RouteMetric=0;InterfaceMetric=1},[pscustomobject]@{InterfaceIndex=9;DestinationPrefix='::/0';RouteMetric=256;InterfaceMetric=35})
    }
}
Run-Test '合成 DNS 与公网测试地址区分' {
    Assert-True (-not (Test-PublicTarget '2001:2::8c')) '把 fake-ip 当成了公网目标'
    Assert-True (-not (Test-PublicTarget 'fd00::1')) '把 ULA 当成了公网目标'
    Assert-True (-not (Test-PublicTarget '2001:db8::1')) '把文档地址当成了公网目标'
    Assert-True (Test-PublicTarget '2400::1') '未识别普通公网地址'
}
Run-Test 'TUN 优先时仍选择有公网地址的 WLAN' {
    $case=New-AdapterCase
    # 选择逻辑使用公网分类；此地址仅在内存中使用，不发起连接。
    $case.Addresses[1].IPAddress='2400::1'
    $selected=Select-IPv6Adapter $case.Adapters $case.Addresses $case.Routes
    Assert-True ($selected.Default.Name -eq '测试隧道' -and $selected.Chosen.Name -eq '无线网络') '虚拟接口遮蔽了物理地址'
}
Run-Test '断开的优先接口不影响默认路径' {
    $case=New-AdapterCase;$case.Adapters[0].Status='Disconnected';$case.Addresses[1].IPAddress='2400::1'
    $selected=Select-IPv6Adapter $case.Adapters $case.Addresses $case.Routes
    Assert-True ($selected.Default.Name -eq '无线网络') '选择了断开的网卡'
}
Run-Test '仅 ULA 隧道也保留默认路径供实际探测' {
    $case=New-AdapterCase;$selected=Select-IPv6Adapter $case.Adapters @($case.Addresses[0]) $case.Routes
    Assert-True ($selected.Chosen.Name -eq '测试隧道') '没有保留 ULA 默认路径'
}
Run-Test '没有默认路由时接口选择为空' {
    $case=New-AdapterCase;$selected=Select-IPv6Adapter $case.Adapters $case.Addresses @()
    Assert-True ($null -eq $selected.Chosen) '没有路由仍选择了接口'
}
Run-Test '虚拟默认路径下不自动修改物理源地址' {
    $case=New-Case;$case.Inventory | Add-Member NoteProperty AlternatePath $true
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '跨接口对照被误用为修复依据'
}
Run-Test '默认源地址未知时不自动修复' {
    $case=New-Case;$case.Inventory.DefaultSources=@{}
    Assert-True (-not (Get-RepairPlan $case.Inventory $case.Targets $case.Probes).CanRepair) '缺少默认源地址仍执行修复'
}
function New-PathCase {
    [pscustomobject]@{Inventory=[pscustomobject]@{DefaultAdapterName='测试隧道';AdapterName='无线网络'};Targets=@([pscustomobject]@{Key='a'},[pscustomobject]@{Key='b'});Probes=@(foreach($key in 'a','b') {
        [pscustomobject]@{TargetKey=$key;SourceAddress='';LocalAddress='fd00::1';Classification='Reachable'}
        [pscustomobject]@{TargetKey=$key;SourceAddress='2001:db8::1';LocalAddress='2001:db8::1';Classification='Reachable'}
    })}
}
Run-Test '默认及公网源地址成功时报告双路径结果' {
    $case=New-PathCase
    Assert-True ((Get-PathAssessment $case.Inventory $case.Targets $case.Probes).Status -eq 'Healthy') '双路径成功未识别'
}
Run-Test '仅 TUN 成功不声称原生 IPv6 健康' {
    $case=New-PathCase;$case.Probes | Where-Object SourceAddress | ForEach-Object {$_.Classification='NetworkFailure'}
    Assert-True ((Get-PathAssessment $case.Inventory $case.Targets $case.Probes).Title -eq '默认路径可用，原生 IPv6 尚未验证') 'TUN 掩盖了源地址失败'
}
Run-Test '绑定源地址与实际地址不一致不报告成功' {
    $case=New-PathCase;$case.Probes | Where-Object SourceAddress | ForEach-Object {$_.LocalAddress='fd00::1'}
    Assert-True ((Get-PathAssessment $case.Inventory $case.Targets $case.Probes).Status -eq 'Inconclusive') '没有核对实际本地地址'
}
Run-Test '源地址成功与默认失败分开反馈' {
    $case=New-PathCase;$case.Probes | Where-Object {-not $_.SourceAddress} | ForEach-Object {$_.Classification='NetworkFailure'}
    Assert-True ((Get-PathAssessment $case.Inventory $case.Targets $case.Probes).Title -eq '源地址可达，默认路径异常') '默认路径失败被掩盖'
}
Run-Test '全部失败与部分目标失败均不报告健康' {
    $case=New-PathCase;$case.Probes | Where-Object TargetKey -eq 'b' | ForEach-Object {$_.Classification='NetworkFailure'}
    Assert-True ((Get-PathAssessment $case.Inventory $case.Targets $case.Probes).Status -eq 'Inconclusive') '单目标成功掩盖其他失败'
    $case.Probes | ForEach-Object {$_.Classification='NetworkFailure'}
    Assert-True ((Get-PathAssessment $case.Inventory $case.Targets $case.Probes).Status -eq 'Inconclusive') '全部失败被判健康'
}
Run-Test '中文记录目录 UTF-8 往返' {
    $directory=Join-Path $testRoot '中文目录';[void](New-Item -ItemType Directory -Path $directory)
    $path=Join-Path $directory '检查结果.json';Save-Json $path ([pscustomobject]@{Message='无线网络检查通过'})
    Assert-True ((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).Message -eq '无线网络检查通过') '中文记录未正确保存'
}

# 以下用内存中的网络模型测试备份、部分失败、验证失败和恢复流程。
function Get-AddressRecord([string]$AdapterGuid,[string]$Address) {
    if($script:virtualAddresses.ContainsKey($Address)){return [pscustomobject]@{IPAddress=$Address;SkipAsSource=$script:virtualAddresses[$Address]}}
    return $null
}
function Set-AddressSelection([string]$AdapterGuid,[string]$Address,[bool]$Skip) {
    if(-not (Test-Path -LiteralPath $script:transactionPath)){throw '首次写入前未保存备份'}
    $script:setCalls++
    if($script:failSecondWrite -and $Skip -and $script:setCalls -eq 2){throw '模拟第二次写入失败'}
    if($script:failRestore -and -not $Skip){throw '模拟恢复写入失败'}
    $script:virtualAddresses[$Address]=$Skip
    if($script:cancelAfterFirst -and $script:setCalls -eq 1){New-Item -ItemType File -Path (Join-Path $script:JobPath 'cancel.request') -Force | Out-Null}
}
function Reset-VirtualCase {
    $script:case=New-Case;$script:plan=Get-RepairPlan $script:case.Inventory $script:case.Targets $script:case.Probes
    $script:virtualAddresses=@{};foreach($address in $script:case.Inventory.Addresses){$script:virtualAddresses[$address.IPAddress]=$false}
    $script:setCalls=0;$script:failSecondWrite=$false;$script:failRestore=$false;$script:cancelAfterFirst=$false
    $script:transactionPath=Join-Path $testRoot ([Guid]::NewGuid().ToString('N')+'.json')
    $cancelPath=Join-Path $script:JobPath 'cancel.request';if(Test-Path -LiteralPath $cancelPath){Remove-Item -LiteralPath $cancelPath}
}
Run-Test '修复前备份，仅修改计划地址并保留可用地址' {
    Reset-VirtualCase;$result=Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $true}
    Assert-True $result.Success '修复未成功'
    Assert-True (-not $script:virtualAddresses[$script:case.Good]) '修改了可用地址'
    Assert-True ($script:setCalls -eq 2) '写入次数不符合两个旧地址'
    Assert-True ((Get-Content -LiteralPath $script:transactionPath -Raw | ConvertFrom-Json).Status -eq 'Verified') '没有记录已验证状态'
}
Run-Test '复测失败自动恢复全部本次修改' {
    Reset-VirtualCase;$result=Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $false}
    Assert-True (-not $result.Success -and $result.Rollback.Success) '验证失败未完成回退'
    Assert-True (@($script:virtualAddresses.Values | Where-Object {$_}).Count -eq 0) '有修改未还原'
}
Run-Test '中途写入失败恢复已应用的修改' {
    Reset-VirtualCase;$script:failSecondWrite=$true
    $result=Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $true}
    Assert-True (-not $result.Success -and $result.Rollback.Success) '中途失败没有回退'
    Assert-True (@($script:virtualAddresses.Values | Where-Object {$_}).Count -eq 0) '部分修改残留'
}
Run-Test '回退失败明确保留未完成状态' {
    Reset-VirtualCase;$script:failRestore=$true
    $result=Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $false}
    Assert-True (-not $result.Success -and -not $result.Rollback.Success) '回退失败被错误报告成功'
    Assert-True ((Get-Content -LiteralPath $script:transactionPath -Raw | ConvertFrom-Json).Status -eq 'RollbackIncomplete') '缺少部分恢复状态'
}
Run-Test '恢复时跳过已自然消失的地址' {
    Reset-VirtualCase;[void](Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $true})
    $script:virtualAddresses.Remove($script:plan.ExcludeAddresses[0]);$transaction=Get-Content -LiteralPath $script:transactionPath -Raw | ConvertFrom-Json
    $result=Restore-Transaction $transaction $script:transactionPath
    Assert-True ($result.Success -and $result.Expired -eq 1) '未正确跳过过期地址'
    Assert-True (-not $script:virtualAddresses[$script:plan.ExcludeAddresses[1]]) '仍存在的旧地址未恢复'
}
Run-Test '修改中取消会还原原值' {
    Reset-VirtualCase;$script:cancelAfterFirst=$true
    $result=Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $true}
    Assert-True ($result.Cancelled -and $result.Rollback.Success) '没有正确保留取消及恢复状态'
    Assert-True (@($script:virtualAddresses.Values | Where-Object {$_}).Count -eq 0) '取消后修改残留'
}
Run-Test '取消时回退失败不会报告已全部恢复' {
    Reset-VirtualCase;$script:cancelAfterFirst=$true;$script:failRestore=$true
    $result=Invoke-RepairPlan $script:case.Inventory $script:plan $script:transactionPath {return $true}
    Assert-True ($result.Cancelled -and -not $result.Rollback.Success) '取消掩盖了回退失败'
    Assert-True ((Get-Content -LiteralPath $script:transactionPath -Raw | ConvertFrom-Json).Status -eq 'RollbackIncomplete') '取消时部分恢复状态丢失'
}

$cancelPath=Join-Path $script:JobPath 'cancel.request';if(Test-Path -LiteralPath $cancelPath){Remove-Item -LiteralPath $cancelPath}
$report=[ordered]@{Time=(Get-Date).ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();Total=$results.Count;Passed=@($results | Where-Object Passed).Count;Tests=$results.ToArray()}
Save-Json (Join-Path $testRoot 'summary.json') $report
Write-Host ('测试结果：'+$report.Passed+'/'+$report.Total+'；'+$testRoot)
if($report.Passed -ne $report.Total){exit 1}
