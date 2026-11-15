using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using MXLink;

namespace MXControlPC;

/// %APPDATA%\MX Control for PC\settings.json. The private key is protected with DPAPI
/// (only this Windows user on this PC can read it).
sealed class Settings : IPinStore
{
    private sealed class Data
    {
        public string? Identity { get; set; }
        public Dictionary<string, string> Pins { get; set; } = [];
        public Dictionary<string, string> PinNames { get; set; } = [];
        public string? MacHost { get; set; }
        public int MacPort { get; set; } = MXLink.Wire.TcpPort;
    }

    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MX Control for PC");
    private static readonly string FilePath = Path.Combine(Folder, "settings.json");
    private readonly Data _data;
    private readonly object _lock = new();

    public Identity Identity { get; }

    public Settings()
    {
        try { _data = JsonSerializer.Deserialize<Data>(File.ReadAllText(FilePath)) ?? new Data(); }
        catch { _data = new Data(); }
        Identity? id = null;
        if (_data.Identity is { } stored)
        {
            try { id = Identity.Import(Dpapi.Unprotect(Convert.FromBase64String(stored)), Environment.MachineName); } catch { }
        }
        if (id is null)
        {
            id = Identity.Create(Environment.MachineName);
            _data.Identity = Convert.ToBase64String(Dpapi.Protect(id.Export()));
            Save();
        }
        Identity = id;
    }

    public string? MacHost { get => _data.MacHost; set { _data.MacHost = value; Save(); } }
    public int MacPort { get => _data.MacPort; set { _data.MacPort = value; Save(); } }
    public string? PairedMacName => _data.PinNames.Values.FirstOrDefault();

    public byte[]? KeyFor(byte[] peerId)
    {
        lock (_lock) return _data.Pins.TryGetValue(Convert.ToHexString(peerId), out var k) ? Convert.FromBase64String(k) : null;
    }

    public void Pin(byte[] peerId, string name, byte[] key)
    {
        lock (_lock)
        {
            var id = Convert.ToHexString(peerId);
            _data.Pins[id] = Convert.ToBase64String(key);
            _data.PinNames[id] = name;
            Save();
        }
    }

    public byte[]? AnyPinnedKey
    {
        get { lock (_lock) return _data.Pins.Values.FirstOrDefault() is { } k ? Convert.FromBase64String(k) : null; }
    }

    public void ForgetMacs()
    {
        lock (_lock) { _data.Pins.Clear(); _data.PinNames.Clear(); Save(); }
    }

    private void Save()
    {
        lock (_lock)
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(_data, new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    // Start with Windows (per user, no admin rights).
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunName = "MX Control for PC";

    public static bool StartWithWindows
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(RunName) is string;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue(RunName, $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue(RunName, false);
        }
    }
}

static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr p);

    private const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    public static byte[] Protect(byte[] data) => Run(data, true);
    public static byte[] Unprotect(byte[] data) => Run(data, false);

    private static byte[] Run(byte[] data, bool protect)
    {
        var handle = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            var input = new Blob { Size = data.Length, Data = handle.AddrOfPinnedObject() };
            var ok = protect
                ? CryptProtectData(ref input, "MX Control for PC", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out var output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out output);
            if (!ok) throw new InvalidOperationException($"DPAPI failed ({Marshal.GetLastWin32Error()})");
            try
            {
                var result = new byte[output.Size];
                Marshal.Copy(output.Data, result, 0, output.Size);
                return result;
            }
            finally { LocalFree(output.Data); }
        }
        finally { handle.Free(); }
    }
}
