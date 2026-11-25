[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source=Join-Path $PSScriptRoot 'src'
$destination=Join-Path $PSScriptRoot '..\dist'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$output=Join-Path $destination 'IPv6修复工具.exe'

# 使用系统自带 .NET Framework 编译器，所有运行代码和诊断脚本嵌入单个 EXE。
$arguments=@('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',
    ('/out:'+$output),('/win32manifest:'+(Join-Path $source 'app.manifest')),
    ('/resource:'+(Join-Path $source 'NetworkEngine.ps1')+',IPv6Repair.NetworkEngine.ps1'),
    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll','/reference:System.Core.dll',
    (Join-Path $source 'IPv6Repair.cs'))
& $compiler @arguments
if($LASTEXITCODE -ne 0){throw '客户端编译失败。'}
Get-Item -LiteralPath $output | Select-Object FullName,Length,LastWriteTime
