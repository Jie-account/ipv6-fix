using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("IPv6 连接修复工具")]
[assembly: AssemblyDescription("按需验证 IPv6 源地址连通性，修复已确认失效的旧源地址选择。")]
[assembly: AssemblyProduct("IPv6 连接修复工具")]
[assembly: AssemblyVersion("1.0.2.0")]
[assembly: AssemblyFileVersion("1.0.2.0")]

namespace IPv6Repair
{
    public sealed class AddressView
    {
        public string AdapterName { get; set; }
        public string IPAddress { get; set; }
        public string State { get; set; }
        public bool SkipAsSource { get; set; }
        public string ProbeStatus { get; set; }
    }

    public sealed class RunReport
    {
        public string Status { get; set; }
        public string Title { get; set; }
        public string Summary { get; set; }
        public string AdapterName { get; set; }
        public string LogDirectory { get; set; }
        public bool CanUndo { get; set; }
        public List<AddressView> Addresses { get; set; }
    }

    public sealed class RepairTransaction
    {
        public int SchemaVersion { get; set; }
        public string Status { get; set; }
        public object[] Changes { get; set; }
    }

    public static class EngineRunner
    {
        // 优先在程序旁保存记录，使客户端和记录可以一起携带。
        public static string GetLogRoot()
        {
            string portable = Path.Combine(Path.GetDirectoryName(typeof(EngineRunner).Assembly.Location), "Logs");
            try
            {
                Directory.CreateDirectory(portable);
                string check = Path.Combine(portable, ".write-" + Guid.NewGuid().ToString("N"));
                File.WriteAllText(check, ""); File.Delete(check);
                return portable;
            }
            catch (UnauthorizedAccessException) { }
            catch (IOException) { }
            string fallback = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "IPv6Repair", "Logs");
            Directory.CreateDirectory(fallback);
            return fallback;
        }

        public static bool HasUndo(string root)
        {
            string directory = Path.Combine(root, "State", "transactions");
            if (!Directory.Exists(directory)) return false;
            foreach (string file in Directory.GetFiles(directory, "*.json"))
            {
                try
                {
                    RepairTransaction item = new JavaScriptSerializer().Deserialize<RepairTransaction>(File.ReadAllText(file, Encoding.UTF8));
                    if (item.SchemaVersion == 1 && item.Status != "RolledBack" && item.Changes != null && item.Changes.Length > 0) return true;
                }
                catch (Exception) { }
            }
            return false;
        }

        public static string CreateJob(string root)
        {
            string path = Path.Combine(root, "Sessions", DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(path);
            return path;
        }

        // 以独立参数启动 PowerShell，不通过 cmd 拼接或执行命令字符串。
        private static string Quote(string value)
        {
            StringBuilder quoted = new StringBuilder("\"");
            int slashes = 0;
            foreach (char ch in value)
            {
                if (ch == '\\') { slashes++; continue; }
                if (ch == '"') { quoted.Append('\\', slashes * 2 + 1); quoted.Append(ch); }
                else { quoted.Append('\\', slashes); quoted.Append(ch); }
                slashes = 0;
            }
            quoted.Append('\\', slashes * 2); quoted.Append('"');
            return quoted.ToString();
        }

        private static string ExtractEngine(string root)
        {
            string text;
            using (Stream resource = typeof(EngineRunner).Assembly.GetManifestResourceStream("IPv6Repair.NetworkEngine.ps1"))
            using (StreamReader reader = new StreamReader(resource, Encoding.UTF8)) text = reader.ReadToEnd();
            string hash;
            using (SHA256 sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", "").Substring(0, 16);
            string directory = Path.Combine(root, "Runtime");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "NetworkEngine-" + hash + ".ps1");
            // Windows PowerShell 5.1 需要 BOM 来正确读取脚本中的中文。
            File.WriteAllText(path, text, new UTF8Encoding(true));
            return path;
        }

        public static RunReport Run(string mode, string root, string job, Action<string> progress)
        {
            string engine = ExtractEngine(root);
            string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            string[] args = { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", engine, "-Mode", mode, "-JobDirectory", job, "-StateDirectory", Path.Combine(root, "State") };
            ProcessStartInfo start = new ProcessStartInfo(shell, string.Join(" ", args.Select(Quote).ToArray()));
            start.UseShellExecute = false; start.CreateNoWindow = true;
            start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            start.StandardOutputEncoding = Encoding.UTF8; start.StandardErrorEncoding = Encoding.UTF8;
            StringBuilder output = new StringBuilder();
            StringBuilder errors = new StringBuilder();
            using (Process worker = new Process())
            {
                worker.StartInfo = start;
                worker.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data == null) return;
                    lock (output) output.AppendLine(e.Data);
                    if (e.Data.StartsWith("PROGRESS|")) progress(e.Data.Substring(9));
                };
                worker.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null) lock (errors) errors.AppendLine(e.Data);
                };
                worker.Start(); worker.BeginOutputReadLine(); worker.BeginErrorReadLine();
                worker.WaitForExit();
            }
            File.WriteAllText(Path.Combine(job, "engine-output.txt"), output.ToString(), new UTF8Encoding(true));
            File.WriteAllText(Path.Combine(job, "engine-errors.txt"), errors.ToString(), new UTF8Encoding(true));
            string resultPath = Path.Combine(job, "result.json");
            if (!File.Exists(resultPath)) throw new InvalidOperationException("诊断进程未返回完整结果。记录已保存至：" + job);
            JavaScriptSerializer serializer = new JavaScriptSerializer(); serializer.MaxJsonLength = 16 * 1024 * 1024;
            RunReport report = serializer.Deserialize<RunReport>(File.ReadAllText(resultPath, Encoding.UTF8));
            if (report == null || string.IsNullOrEmpty(report.Status)) throw new InvalidOperationException("诊断结果无法读取。");
            return report;
        }
    }

    internal sealed class CardPanel : TableLayoutPanel
    {
        public CardPanel()
        {
            DoubleBuffered = true; BackColor = Color.White; Padding = new Padding(20);
            ColumnCount = 1; RowCount = 2; ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            RowStyles.Add(new RowStyle(SizeType.AutoSize)); RowStyles.Add(new RowStyle(SizeType.AutoSize));
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen pen = new Pen(Color.FromArgb(222, 229, 240)))
                e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
        }
    }

    public sealed class MainForm : Form
    {
        private readonly Color blue = Color.FromArgb(38, 97, 219);
        private readonly Color ink = Color.FromArgb(28, 43, 66);
        private readonly Color muted = Color.FromArgb(98, 113, 135);
        private readonly Label stateTitle = new Label();
        private readonly Label stateSummary = new Label();
        private readonly Label symbol = new Label();
        private readonly Label stage = new Label();
        private readonly Label footer = new Label();
        private readonly ProgressBar progress = new ProgressBar();
        private readonly Button repair = new Button();
        private readonly Button check = new Button();
        private readonly Button undo = new Button();
        private readonly Button logs = new Button();
        private readonly Button cancel = new Button();
        private readonly DataGridView grid = new DataGridView();
        private readonly TextBox activity = new TextBox();
        private readonly string logRoot;
        private string jobPath;
        private string lastLogPath;
        private bool busy;
        private bool closeAfterStop;

        public MainForm(string root)
        {
            SuspendLayout();
            // 明确 96 DPI 设计基准，让首次启动时的字体和布局一起缩放。
            AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
            logRoot = root; lastLogPath = root;
            Text = "IPv6 连接修复";
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Color.FromArgb(244, 247, 252);
            ForeColor = ink; ClientSize = new Size(1040, 740); MinimumSize = new Size(840, 640);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = SystemIcons.Shield;

            Panel viewport = new Panel(); viewport.Name = "ContentViewport";
            viewport.Dock = DockStyle.Fill; viewport.AutoScroll = true; Controls.Add(viewport);
            TableLayoutPanel layout = new TableLayoutPanel();
            layout.Name = "MainLayout";
            layout.Dock = DockStyle.Top; layout.AutoSize = true; layout.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            layout.Padding = new Padding(26, 22, 26, 18);
            layout.ColumnCount = 1; layout.RowCount = 5;
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            viewport.Controls.Add(layout);
            Action fitWidth = delegate {
                int availableWidth = Math.Max(1, viewport.ClientSize.Width);
                layout.MaximumSize = new Size(availableWidth, 0);
                layout.MinimumSize = new Size(availableWidth, viewport.ClientSize.Height);
            };
            viewport.ClientSizeChanged += delegate { fitWidth(); };
            fitWidth();

            // 标题、说明和帮助链接用自动行高排布，字号变化时不再共享固定坐标。
            TableLayoutPanel header = new TableLayoutPanel(); header.Dock = DockStyle.Fill;
            header.Name = "HeaderPanel";
            header.AutoSize = true; header.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            header.ColumnCount = 2; header.RowCount = 2; header.Margin = new Padding(0, 0, 0, 16);
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            header.RowStyles.Add(new RowStyle(SizeType.AutoSize)); header.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Label title = new Label(); title.Text = "IPv6 连接修复"; title.Font = new Font(Font.FontFamily, 23F, FontStyle.Bold);
            title.Name = "HeaderTitle"; title.AutoSize = true; title.Dock = DockStyle.Fill; title.Margin = new Padding(0, 0, 20, 0); header.Controls.Add(title, 0, 0);
            Label tagline = new Label(); tagline.Text = "检查睡眠唤醒后的 IPv6 连接，修复已证实失效的旧源地址选择。";
            tagline.Name = "HeaderSubtitle"; tagline.AutoSize = true; tagline.Dock = DockStyle.Fill; tagline.ForeColor = muted;
            tagline.Margin = new Padding(2, 8, 0, 0); header.Controls.Add(tagline, 0, 1); header.SetColumnSpan(tagline, 2);
            LinkLabel help = new LinkLabel(); help.Text = "根治与使用说明"; help.AutoSize = true;
            help.Name = "HelpLink"; help.Anchor = AnchorStyles.Top | AnchorStyles.Right; help.Margin = new Padding(8, 12, 0, 0); help.LinkColor = blue;
            help.LinkClicked += delegate { ShowHelp(); }; header.Controls.Add(help, 1, 0);
            layout.Controls.Add(header, 0, 0);

            CardPanel state = new CardPanel(); state.Dock = DockStyle.Fill; state.Margin = new Padding(0, 0, 0, 10);
            state.Name = "StatusCard";
            state.AutoSize = true; state.AutoSizeMode = AutoSizeMode.GrowAndShrink; state.MinimumSize = new Size(0, 136);
            TableLayoutPanel stateLayout = new TableLayoutPanel(); stateLayout.Dock = DockStyle.Top;
            stateLayout.AutoSize = true; stateLayout.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            stateLayout.ColumnCount = 2; stateLayout.RowCount = 3;
            stateLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); stateLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            stateLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); stateLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); stateLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            symbol.Text = "6"; symbol.Font = new Font("Segoe UI", 28F, FontStyle.Bold); symbol.ForeColor = blue;
            symbol.BackColor = Color.FromArgb(235, 242, 255); symbol.TextAlign = ContentAlignment.MiddleCenter;
            symbol.AutoSize = true; symbol.MinimumSize = new Size(60, 66); symbol.Margin = new Padding(0, 4, 18, 0); stateLayout.Controls.Add(symbol, 0, 0); stateLayout.SetRowSpan(symbol, 2);
            stateTitle.Name = "StatusTitle"; stateTitle.AutoSize = true; stateTitle.Margin = new Padding(0, 0, 0, 6);
            stateTitle.Text = "准备检查 IPv6"; stateTitle.Font = new Font(Font.FontFamily, 17F, FontStyle.Bold); stateTitle.Dock = DockStyle.Fill;
            stateSummary.Text = "点击“检查并修复”。工具会先验证连接，只在确认此类地址故障后应用修复。";
            stateSummary.Name = "StatusSummary"; stateSummary.AutoSize = true; stateSummary.Margin = new Padding(0, 2, 0, 8);
            stateSummary.Dock = DockStyle.Fill; stateSummary.ForeColor = muted;
            stage.Name = "StatusStage"; stage.AutoSize = true; stage.Margin = new Padding(0, 4, 0, 0);
            stage.Dock = DockStyle.Fill; stage.ForeColor = muted; stage.Font = new Font(Font.FontFamily, 8F); stage.Text = "按需运行 · 修改前自动保存原值";
            stateLayout.Controls.Add(stateTitle, 1, 0); stateLayout.Controls.Add(stateSummary, 1, 1); stateLayout.Controls.Add(stage, 1, 2);
            progress.Dock = DockStyle.Bottom; progress.Height = 3; progress.Visible = false; progress.Style = ProgressBarStyle.Marquee;
            state.Controls.Add(stateLayout); state.Controls.Add(progress); layout.Controls.Add(state, 0, 1);

            FlowLayoutPanel actions = new FlowLayoutPanel(); actions.Dock = DockStyle.Fill; actions.WrapContents = true;
            actions.Name = "ActionBar";
            actions.AutoSize = true; actions.AutoSizeMode = AutoSizeMode.GrowAndShrink; actions.Padding = new Padding(0, 6, 0, 6); actions.Margin = new Padding(0, 0, 0, 10);
            ConfigureButton(repair, "检查并修复 IPv6", 212, true);
            ConfigureButton(check, "仅检查", 112, false);
            ConfigureButton(undo, "恢复上次修改", 145, false);
            ConfigureButton(logs, "打开记录", 116, false);
            ConfigureButton(cancel, "停止", 82, false); cancel.Enabled = false;
            undo.Enabled = !string.IsNullOrEmpty(root) && EngineRunner.HasUndo(root);
            actions.Controls.AddRange(new Control[] { repair, check, undo, logs, cancel }); layout.Controls.Add(actions, 0, 2);
            repair.Click += async delegate { await RunOperation("Repair"); };
            check.Click += async delegate { await RunOperation("Check"); };
            undo.Click += async delegate { await RunOperation("Rollback"); };
            cancel.Click += delegate { RequestStop(); };
            logs.Click += delegate
            {
                try { Directory.CreateDirectory(lastLogPath); Process.Start(new ProcessStartInfo(lastLogPath) { UseShellExecute = true }); }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "无法打开记录", MessageBoxButtons.OK, MessageBoxIcon.Information); }
            };

            TabControl tabs = new TabControl(); tabs.Name = "DetailsTabs"; tabs.Dock = DockStyle.Fill; tabs.MinimumSize = new Size(0, 110);
            TabPage addresses = new TabPage("地址明细"); TabPage events = new TabPage("运行记录");
            addresses.BackColor = Color.White; events.BackColor = Color.White;
            grid.Dock = DockStyle.Fill; grid.BackgroundColor = Color.White; grid.BorderStyle = BorderStyle.None;
            grid.ReadOnly = true; grid.AllowUserToAddRows = false; grid.AllowUserToDeleteRows = false; grid.AllowUserToResizeRows = false;
            grid.RowHeadersVisible = false; grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill; grid.EnableHeadersVisualStyles = false;
            grid.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(242, 246, 251); grid.ColumnHeadersDefaultCellStyle.ForeColor = muted;
            grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Color.FromArgb(242, 246, 251); grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = muted;
            grid.ColumnHeadersDefaultCellStyle.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold);
            grid.ColumnHeadersDefaultCellStyle.Padding = new Padding(7, 8, 7, 8);
            grid.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize;
            grid.DefaultCellStyle.Padding = new Padding(7, 9, 7, 9); grid.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells;
            grid.DefaultCellStyle.SelectionBackColor = Color.FromArgb(232, 241, 255); grid.DefaultCellStyle.SelectionForeColor = ink;
            grid.GridColor = Color.FromArgb(234, 239, 246); grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
            grid.Columns.Add("Adapter", "网卡"); grid.Columns.Add("Address", "IPv6 地址"); grid.Columns.Add("Probe", "检测结果"); grid.Columns.Add("Selection", "自动选用");
            grid.Columns[0].FillWeight = 13; grid.Columns[1].FillWeight = 48; grid.Columns[2].FillWeight = 27; grid.Columns[3].FillWeight = 12;
            grid.Columns[1].DefaultCellStyle.Font = new Font("Consolas", 9F);
            addresses.Controls.Add(grid);
            activity.Multiline = true; activity.ReadOnly = true; activity.ScrollBars = ScrollBars.Vertical; activity.Dock = DockStyle.Fill;
            activity.BorderStyle = BorderStyle.None; activity.BackColor = Color.White; activity.Font = new Font("Microsoft YaHei UI", 9F);
            activity.Text = "这里会显示检查过程与结果。详细诊断会自动保存到记录文件夹。" + Environment.NewLine;
            events.Controls.Add(activity); tabs.TabPages.Add(addresses); tabs.TabPages.Add(events); layout.Controls.Add(tabs, 0, 3);

            footer.Text = "本工具处理失效旧源地址选择；长期根治仍需纠正前缀退役机制。";
            footer.Name = "FooterText"; footer.AutoSize = true; footer.Dock = DockStyle.Fill; footer.ForeColor = muted;
            footer.Margin = new Padding(0, 14, 0, 0); footer.Font = new Font(Font.FontFamily, 8F);
            layout.Controls.Add(footer, 0, 4);
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!busy) return;
                e.Cancel = true; closeAfterStop = true; RequestStop();
            };
            ResumeLayout(true);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            // 高 DPI 时保留完整窗口，额外空间让给可伸缩的明细区。
            Rectangle area = Screen.FromControl(this).WorkingArea;
            Size limit = new Size(Math.Max(500, area.Width - 32), Math.Max(480, area.Height - 40));
            MinimumSize = new Size(Math.Min(MinimumSize.Width, limit.Width), Math.Min(MinimumSize.Height, limit.Height));
            Size = new Size(Math.Min(Width, limit.Width), Math.Min(Height, limit.Height));
            if (StartPosition == FormStartPosition.CenterScreen)
                Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
        }

        private void ConfigureButton(Button button, string text, int width, bool primary)
        {
            button.Text = text; button.MinimumSize = new Size(width, 44); button.AutoSize = true; button.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            button.Padding = new Padding(12, 4, 12, 4); button.Margin = new Padding(0, 0, 10, 8);
            button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.BorderColor = Color.FromArgb(211, 221, 236);
            button.BackColor = primary ? blue : Color.White; button.ForeColor = primary ? Color.White : ink;
            button.Cursor = Cursors.Hand; button.Font = new Font(Font.FontFamily, 9F, primary ? FontStyle.Bold : FontStyle.Regular);
            button.AccessibleName = text;
        }

        private void Post(Action action)
        {
            if (IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(action); } catch (InvalidOperationException) { }
        }

        private void AppendActivity(string text)
        {
            stage.Text = text;
            activity.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + text + Environment.NewLine);
        }

        private void RequestStop()
        {
            if (!busy || string.IsNullOrEmpty(jobPath)) return;
            try { File.WriteAllText(Path.Combine(jobPath, "cancel.request"), ""); cancel.Enabled = false; AppendActivity("正在停止，请等待当前操作完成并保存记录…"); }
            catch (Exception ex) { AppendActivity("无法发送停止请求：" + ex.Message); }
        }

        private async Task RunOperation(string mode)
        {
            if (busy) return;
            busy = true; repair.Enabled = false; check.Enabled = false; undo.Enabled = false; cancel.Enabled = true;
            progress.Visible = true; stateTitle.Text = mode == "Rollback" ? "正在恢复原值" : "正在检查 IPv6";
            stateSummary.Text = "正在核对实际连接与地址状态，完成后会自动显示结果。";
            stateTitle.ForeColor = ink; symbol.Text = "…"; symbol.ForeColor = blue;
            try
            {
                jobPath = EngineRunner.CreateJob(logRoot); lastLogPath = jobPath;
                AppendActivity("开始操作，记录已创建。");
                RunReport result = await Task.Run(() => EngineRunner.Run(mode, logRoot, jobPath, message => Post(() => AppendActivity(message))));
                ShowReport(result);
            }
            catch (Exception ex)
            {
                ShowReport(new RunReport { Status = "Error", Title = "本次操作未完成", Summary = ex.Message, LogDirectory = lastLogPath, CanUndo = EngineRunner.HasUndo(logRoot) });
            }
            finally
            {
                busy = false; repair.Enabled = true; check.Enabled = true; cancel.Enabled = false; progress.Visible = false;
                if (closeAfterStop) Close();
            }
        }

        public void ShowReport(RunReport report)
        {
            Color color = blue;
            if (report.Status == "Healthy" || report.Status == "Repaired") color = Color.FromArgb(22, 129, 91);
            else if (report.Status == "NeedsRepair" || report.Status == "Inconclusive" || report.Status == "NotThisIssue") color = Color.FromArgb(170, 111, 21);
            else if (report.Status == "Error" || report.Status == "RepairFailed" || report.Status == "RollbackPartial") color = Color.FromArgb(190, 60, 64);
            stateTitle.Text = report.Title; stateTitle.ForeColor = color; stateSummary.Text = report.Summary;
            symbol.Text = report.Status == "Healthy" || report.Status == "Repaired" ? "✓" : "i";
            symbol.ForeColor = color;
            stage.Text = "操作已完成 · 详细诊断记录已保存";
            undo.Enabled = report.CanUndo;
            if (!string.IsNullOrEmpty(report.LogDirectory)) lastLogPath = report.LogDirectory;
            grid.Rows.Clear();
            if (report.Addresses != null)
                foreach (AddressView address in report.Addresses)
                    grid.Rows.Add(address.AdapterName, address.IPAddress, address.ProbeStatus, address.SkipAsSource ? "已排除" : "可选用");
            grid.CurrentCell = null; grid.ClearSelection();
            activity.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + report.Title + Environment.NewLine + report.Summary + Environment.NewLine + "记录：" + lastLogPath + Environment.NewLine);
        }

        private void ShowHelp()
        {
            MessageBox.Show(this,
                "当前做法\n保留已经恢复的设置。再次出现问题时，点击“检查并修复 IPv6”。工具会比较同一目标使用不同源地址的连接，只排除已重复证实失效的旧源地址，并复测结果。\n\n" +
                "有没有办法根治\n长期需要让网络撤换前缀时，电脑及时弃用旧地址。现在已经确认源地址选择是直接原因；网络通告、地址绑定或终端处理中的具体责任尚待进一步抓包确认。本工具提供按需恢复，不保证消除前缀再次变化后的复发。\n\n" +
                "备份和恢复\n修改前自动保存原值，复测失败时自动还原。点击“恢复上次修改”可恢复本工具最近一次修改；这可能让尚未过期的旧地址重新参与选择。\n\n" +
                "携带使用\n只需携带这个 EXE。记录优先保存在程序旁的 Logs 文件夹；程序所在位置只读时，保存到当前用户的本地应用数据目录。工具按需运行，不安装后台任务。",
                "根治与使用说明", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    public static class Program
    {
        [STAThread]
        public static void Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                string root = EngineRunner.GetLogRoot();
                if (args.Length > 0 && (args[0] == "--check" || args[0] == "--repair"))
                {
                    string job = EngineRunner.CreateJob(root);
                    RunReport result = EngineRunner.Run(args[0] == "--check" ? "Check" : "Repair", root, job, delegate { });
                    Environment.ExitCode = result.Status == "Error" || result.Status == "RollbackPartial" || result.Status == "RepairFailed" ? 1 : 0;
                    return;
                }
                Application.Run(new MainForm(root));
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "IPv6 连接修复", MessageBoxButtons.OK, MessageBoxIcon.Error); Environment.ExitCode = 1; }
        }

        // 供本地视觉验证使用，只渲染界面，不运行检测或修改网络。
        public static void RenderForTest(string path, string scenario)
        {
            RenderScaledForTest(path, scenario, 1F, 1040, 740);
        }

        private static IEnumerable<Control> Descendants(Control parent)
        {
            yield return parent;
            foreach (Control child in parent.Controls)
                foreach (Control item in Descendants(child)) yield return item;
        }

        // 在当前系统 DPI 上额外放大文字，回归字体变大但布局不增长的重叠问题。
        public static string[] RenderScaledForTest(string path, string scenario, float textScale, int width, int height)
        {
            Application.EnableVisualStyles();
            using (MainForm form = new MainForm(null))
            {
                float dpiScale;
                using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) dpiScale = g.DpiX / 96F;
                form.ClientSize = new Size((int)Math.Round(width * dpiScale), (int)Math.Round(height * dpiScale));
                if (scenario == "repaired")
                    form.ShowReport(new RunReport {
                        Status="Repaired", Title="IPv6 已恢复", Summary="已避开 2 个失效旧源地址，默认连接复测通过。地址和默认路由保持，未重启网卡。",
                        LogDirectory="演示界面 · 未执行网络修改", CanUndo=true,
                        Addresses=new List<AddressView> {
                            new AddressView { AdapterName="WLAN", IPAddress="2001:db8:3::10", ProbeStatus="可用", SkipAsSource=false },
                            new AddressView { AdapterName="WLAN", IPAddress="2001:db8:1::10", ProbeStatus="已排除自动选择", SkipAsSource=true },
                            new AddressView { AdapterName="WLAN", IPAddress="2001:db8:2::10", ProbeStatus="已排除自动选择", SkipAsSource=true }
                        }
                    });
                else if (scenario == "long")
                    form.ShowReport(new RunReport {
                        Status="Inconclusive", Title="网络状态正在变化，请重新检查",
                        Summary="检查期间 IPv6 地址或路由发生变化，尚未形成足以自动修复的重复对照证据。本次保持网络设置原状，完整诊断记录已经保存，可以在连接稳定后重新点击检查。",
                        LogDirectory="演示界面 · 未执行网络修改", CanUndo=false
                    });
                if (textScale != 1F)
                {
                    List<Control> controls = Descendants(form).ToList();
                    List<Font> fonts = controls.Select(control => control.Font).ToList();
                    form.SuspendLayout();
                    for (int i = 0; i < controls.Count; i++)
                        controls[i].Font = new Font(fonts[i].FontFamily, fonts[i].SizeInPoints * textScale, fonts[i].Style);
                    form.ResumeLayout(true);
                }
                form.ShowInTaskbar = false; form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-32000, -32000);
                form.Show(); Application.DoEvents(); form.PerformLayout(); form.Refresh();
                List<string> failures = new List<string>();
                List<Label> labels = Descendants(form).OfType<Label>().Where(label => !string.IsNullOrEmpty(label.Name)).ToList();
                foreach (Label label in labels)
                {
                    Size needed = TextRenderer.MeasureText(label.Text, label.Font,
                        new Size(Math.Max(1, label.ClientSize.Width - label.Padding.Horizontal), int.MaxValue),
                        TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl);
                    if (needed.Height > label.ClientSize.Height - label.Padding.Vertical + 2)
                        failures.Add(label.Name + ": text clipped (needs " + needed.Height + ", has " + label.ClientSize.Height + ")");
                    Rectangle bounds = new Rectangle(label.PointToScreen(Point.Empty), label.Size);
                    for (Control ancestor = label.Parent; ancestor != null && ancestor.Name != "ContentViewport"; ancestor = ancestor.Parent)
                    {
                        Rectangle clip = ancestor.RectangleToScreen(ancestor.ClientRectangle);
                        if (!clip.Contains(bounds)) failures.Add(label.Name + ": clipped by " + ancestor.Name);
                    }
                }
                for (int left = 0; left < labels.Count; left++)
                    for (int right = left + 1; right < labels.Count; right++)
                    {
                        Rectangle a = new Rectangle(labels[left].PointToScreen(Point.Empty), labels[left].Size);
                        Rectangle b = new Rectangle(labels[right].PointToScreen(Point.Empty), labels[right].Size);
                        a.Inflate(-1, -1); b.Inflate(-1, -1);
                        if (a.IntersectsWith(b)) failures.Add(labels[left].Name + " overlaps " + labels[right].Name);
                    }
                List<Control> blocks = Descendants(form).Where(control => new string[] { "HeaderPanel", "StatusCard", "ActionBar", "DetailsTabs", "FooterText" }.Contains(control.Name)).ToList();
                for (int left = 0; left < blocks.Count; left++)
                    for (int right = left + 1; right < blocks.Count; right++)
                    {
                        Rectangle a = blocks[left].RectangleToScreen(blocks[left].ClientRectangle);
                        Rectangle b = blocks[right].RectangleToScreen(blocks[right].ClientRectangle);
                        a.Inflate(-1, -1); b.Inflate(-1, -1);
                        if (a.IntersectsWith(b)) failures.Add(blocks[left].Name + " overlaps " + blocks[right].Name);
                    }
                using (Bitmap bitmap = new Bitmap(form.Width, form.Height))
                {
                    form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                    bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
                }
                return failures.ToArray();
            }
        }
    }
}
