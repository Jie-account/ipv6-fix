[CmdletBinding()]
param([switch]$SkipBuild)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if(-not $SkipBuild){& (Join-Path $PSScriptRoot 'Build.ps1')}
$destination=Join-Path $PSScriptRoot '..\dist'
$executable=Join-Path $destination 'IPv6修复工具.exe'
$readme=Join-Path $destination '使用说明.txt'
$archive=Join-Path $destination 'IPv6Repair-win-x64.zip'
$body=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Portable-Readme.txt'),[Text.Encoding]::UTF8)
[IO.File]::WriteAllText($readme,$body,[Text.UTF8Encoding]::new($true))
# 只打包程序与公开说明，运行记录和个人诊断材料不进入发布包。
Compress-Archive -LiteralPath $executable,$readme -DestinationPath $archive -Force
Copy-Item -LiteralPath $archive -Destination (Join-Path $destination 'IPv6修复工具-便携版.zip') -Force
Get-FileHash -LiteralPath $executable,$archive -Algorithm SHA256 | ForEach-Object {
    $_.Hash+'  '+[IO.Path]::GetFileName($_.Path)
} | Set-Content -LiteralPath (Join-Path $destination 'SHA256.txt') -Encoding UTF8
Get-Item -LiteralPath $executable,$archive | Select-Object FullName,Length
