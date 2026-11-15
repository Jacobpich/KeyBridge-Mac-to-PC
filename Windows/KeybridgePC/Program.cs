namespace KeybridgePC;

static class Program
{
    [STAThread]
    static void Main()
    {
        using var single = new Mutex(true, @"Local\KeybridgePC", out var first);
        if (!first) return;  // already running (it lives in the tray)
        // This app replaces "MX Control for PC"; two of them would fight over the link.
        foreach (var old in System.Diagnostics.Process.GetProcessesByName("MXControlPC"))
        {
            try { old.Kill(); old.WaitForExit(3000); } catch { }
        }
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayApp());
    }
}
