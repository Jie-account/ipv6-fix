using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace IPv6Repair
{
    public static class LayoutTestProgram
    {
        [STAThread]
        public static int Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            string root = args[0]; Directory.CreateDirectory(root);
            List<object> results = new List<object>(); int errors = 0;
            float dpi;
            using (Graphics graphics = Graphics.FromHwnd(IntPtr.Zero)) dpi = graphics.DpiX;
            foreach (float scale in new float[] { 1F, 1.25F, 1.5F, 2F })
                foreach (string scenario in new string[] { "ready", "repaired", "long" })
                {
                    string name = ((int)(scale * 100)).ToString() + "-" + scenario;
                    string[] failures = Program.RenderScaledForTest(Path.Combine(root, name + ".png"), scenario, scale, 1040, 740);
                    results.Add(new { Name=name, TextScale=scale, Scenario=scenario, Failures=failures });
                    errors += failures.Length; Console.WriteLine(name + ": " + (failures.Length == 0 ? "PASS" : string.Join("; ", failures)));
                }
            foreach (string scenario in new string[] { "ready", "repaired" })
            {
                string name = "compact-125-" + scenario;
                string[] failures = Program.RenderScaledForTest(Path.Combine(root, name + ".png"), scenario, 1.25F, 840, 640);
                results.Add(new { Name=name, TextScale=1.25F, Scenario=scenario, Failures=failures });
                errors += failures.Length; Console.WriteLine(name + ": " + (failures.Length == 0 ? "PASS" : string.Join("; ", failures)));
            }
            File.WriteAllText(Path.Combine(root, "summary.json"), new JavaScriptSerializer().Serialize(new { SystemDpi=dpi, Cases=results, Errors=errors }), new UTF8Encoding(true));
            return errors == 0 ? 0 : 1;
        }
    }
}
