// OpenThinRDP Manager launcher: starts OpenThinRDP-Manager.ps1, next to this program, with Windows PowerShell and no
// console window, so the manager can be pinned and started like any program, with the OpenThinRDP icon.
// Arguments: those in <program name>.args next to it (one line, e.g. -Folder "\\fileserver\thinclients" -Language it),
// then those given to the program. A copy on the local disk finds the manager through <program name>.script.
// Built by build-launcher.ps1 with the C# compiler of .NET Framework (C# 5).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

static class Launcher {
    [STAThread]
    static int Main(string[] args) {
        string exe = Assembly.GetExecutingAssembly().Location, dir = Path.GetDirectoryName(exe);
        string ps1 = Path.Combine(dir, "OpenThinRDP-Manager.ps1");
        // A copy of this program on the local disk (Windows shows the icon of a shortcut only for a local program):
        // <program name>.script says where the manager is, e.g. \\fileserver\it\manager\OpenThinRDP-Manager.ps1
        string scriptFile = Path.ChangeExtension(exe, ".script");
        if (!File.Exists(ps1) && File.Exists(scriptFile)) ps1 = File.ReadAllText(scriptFile).Trim().Trim('"');
        if (!File.Exists(ps1)) {
            MessageBox.Show("The manager was not found: " + ps1 + ".", "OpenThinRDP Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        dir = Path.GetDirectoryName(ps1);
        string extra = "", argsFile = Path.ChangeExtension(exe, ".args");
        if (File.Exists(argsFile)) extra = File.ReadAllText(argsFile).Replace('\r', ' ').Replace('\n', ' ').Trim();
        StringBuilder line = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ").Append(Quote(ps1));
        if (extra.Length > 0) line.Append(' ').Append(extra);
        foreach (string a in args) line.Append(' ').Append(Quote(a));
        ProcessStartInfo p = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), line.ToString());
        p.UseShellExecute = false; p.CreateNoWindow = true; p.WorkingDirectory = dir;
        try { Process.Start(p); }
        catch (Exception e) {
            MessageBox.Show("Windows PowerShell could not be started: " + e.Message, "OpenThinRDP Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }
    // one argument as the C runtime of Windows reads it back: in quotes when needed, backslashes before a quote doubled
    static string Quote(string a) {
        if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return a;
        StringBuilder s = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in a) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { s.Append('\\', slashes * 2 + 1).Append('"'); }
            else { s.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        s.Append('\\', slashes * 2).Append('"');
        return s.ToString();
    }
}
