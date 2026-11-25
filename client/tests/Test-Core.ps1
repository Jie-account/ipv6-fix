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
