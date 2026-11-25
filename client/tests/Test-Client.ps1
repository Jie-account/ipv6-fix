[CmdletBinding()]
param([string]$ProjectRoot,[switch]$Smoke)

$ErrorActionPreference='Stop'
if(-not $ProjectRoot){$ProjectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions
[void][Reflection.Assembly]::LoadFrom((Join-Path $ProjectRoot 'dist\IPv6修复工具.exe'))
$output=Join-Path $ProjectRoot 'client\test-results'
New-Item -ItemType Directory -Path $output -Force | Out-Null
[IPv6Repair.Program]::RenderForTest((Join-Path $output 'ready.png'),'ready')
[IPv6Repair.Program]::RenderForTest((Join-Path $output 'repaired.png'),'repaired')

if($Smoke){
    # 在屏幕外触发真实“仅检查”按钮，测试完整 UI、子进程和结果显示链路。
    $root=Join-Path $output 'ui-smoke'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $form=[IPv6Repair.MainForm]::new($root)
    $flags=[Reflection.BindingFlags]'Instance,NonPublic'
    $form.ShowInTaskbar=$false
    $form.StartPosition=[Windows.Forms.FormStartPosition]::Manual
    $form.Location=[Drawing.Point]::new(-32000,-32000)
    $form.Show()
    $check=$form.GetType().GetField('check',$flags).GetValue($form)
    $check.PerformClick()
    $deadline=(Get-Date).AddSeconds(120)
    while([bool]$form.GetType().GetField('busy',$flags).GetValue($form) -and (Get-Date) -lt $deadline){
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    if([bool]$form.GetType().GetField('busy',$flags).GetValue($form)){$form.Close();throw '客户端只读联调超时。'}
    $status=$form.GetType().GetField('stateTitle',$flags).GetValue($form).Text
    $lastPath=$form.GetType().GetField('lastLogPath',$flags).GetValue($form)
    $result=Get-Content -LiteralPath (Join-Path $lastPath 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($status -ne $result.Title){throw '客户端未显示后台结果。'}
    if(@($result.Changes).Count -ne 0){throw '仅检查模式产生了修改。'}
    $form.Refresh()
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height));$bitmap.Save((Join-Path $output 'live-client.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose();$form.Close();$form.Dispose()}
    [ordered]@{Time=(Get-Date).ToString('o');Status=$result.Status;Title=$status;NetworkChanges=@($result.Changes).Count;ReportDirectory=$lastPath} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'ui-smoke-summary.json') -Encoding UTF8
    Write-Output ('客户端只读联调通过：'+$status)
}
