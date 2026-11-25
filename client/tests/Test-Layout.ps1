[CmdletBinding()]
param([string]$ProjectRoot)
$ErrorActionPreference='Stop'
if(-not $ProjectRoot){$ProjectRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$destination=Join-Path $ProjectRoot 'client\test-results\layout'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$executable=Join-Path $destination 'LayoutTest.exe'
$arguments=@('/nologo','/target:exe','/platform:x64','/codepage:65001','/main:IPv6Repair.LayoutTestProgram',
    ('/out:'+$executable),('/win32manifest:'+(Join-Path $ProjectRoot 'client\tests\layout.manifest')),
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll','/reference:System.Core.dll',
    (Join-Path $ProjectRoot 'client\src\IPv6Repair.cs'),(Join-Path $ProjectRoot 'client\tests\LayoutTest.cs'))
& $compiler @arguments
if($LASTEXITCODE -ne 0){throw '布局测试程序编译失败。'}
& $executable $destination
if($LASTEXITCODE -ne 0){throw '存在文字裁切、重叠或越出窗口的问题。'}
