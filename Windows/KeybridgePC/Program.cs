namespace KeybridgePC;

static class Program
{
    [STAThread]
    static void Main()
    {
        // This app replaces earlier versions under other names ("MX Control for PC", then
        // "Keybridge"); two of them would fight over the link. Close them first, since 1.1.0
        // also holds the single-instance lock below.
        foreach (var name in new[] { "MXControlPC", "Keybridge" })
            foreach (var old in System.Diagnostics.Process.GetProcessesByName(name))
            {
                try { old.Kill(); old.WaitForExit(3000); } catch { }
            }
        using var single = new Mutex(true, @"Local\KeybridgePC", out var first);
        if (!first) return;  // already running (it lives in the tray)
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayApp());
    }
}
