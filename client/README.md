# 客户端开发入口

使用方法见[使用说明](../docs/usage.md)，下载见[GitHub Releases](https://github.com/Jie-account/ipv6-fix/releases/latest)。

| 文件 | 职责 |
|---|---|
| [IPv6Repair.cs](src/IPv6Repair.cs) | 自适应 WinForms 界面、内嵌脚本启动、进度和结果反馈 |
| [NetworkEngine.ps1](src/NetworkEngine.ps1) | 动态采集、逐源对照、修复计划、备份和恢复 |
| [app.manifest](src/app.manifest) | 管理员权限与系统 DPI 声明 |
| [Build.ps1](Build.ps1) / [Package.ps1](Package.ps1) | 单文件程序构建和便携包打包 |
| [Test-Core.ps1](tests/Test-Core.ps1) | 合成故障回放与内存写入/恢复测试 |
| [Test-Layout.ps1](tests/Test-Layout.ps1) | 使用真实 DPI 声明的布局回归测试 |
| [Test-Client.ps1](tests/Test-Client.ps1) | 界面渲染，及可选的真实“仅检查”按钮联调 |

在项目根执行：

~~~powershell
.\client\Package.ps1
.\client\tests\Test-Core.ps1 -ProjectRoot (Get-Location).Path
.\client\tests\Test-Layout.ps1 -ProjectRoot (Get-Location).Path
~~~

若需真实网络的只读按钮联调，在 Windows PowerShell 5.1 运行：

~~~powershell
.\client\tests\Test-Client.ps1 -ProjectRoot (Get-Location).Path -Smoke
~~~

PowerShell 文件使用 UTF-8 BOM，保证 Windows PowerShell 5.1 正确读取中文。自动逻辑与布局测试不会修改真实网卡；`-Smoke` 会发出只读网络探测，产生的记录位于已忽略的 `client/test-results`。

界面以 96 DPI 为设计基准，文字使用自动行高，容器宽度受窗口约束。大字号长内容在纵向滚动区内排布，按钮和说明可换行。布局测试额外放大文字，不修改 Windows 的全局显示设置。
