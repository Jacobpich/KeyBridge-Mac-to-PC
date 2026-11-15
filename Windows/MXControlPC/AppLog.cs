namespace MXControlPC;

/// %LOCALAPPDATA%\MX Control for PC\log.txt: what Crossover did, for working out problems.
static class AppLog
{
    public static readonly string File = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MX Control for PC", "log.txt");
    private static readonly object Gate = new();

    public static void Write(string line)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(File)!);
                if (System.IO.File.Exists(File) && new FileInfo(File).Length > 1_000_000)
                    System.IO.File.Move(File, File + ".old", true);
                System.IO.File.AppendAllText(File, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
