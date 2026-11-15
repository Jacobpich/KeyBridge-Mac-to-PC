// MXLink probe: the C# protocol code running as a pretend PC, so the Windows side's crypto and
// framing can be checked against MX Control on the Mac.
//   dotnet run --project Windows/Probe -- [--host 127.0.0.1] [--discover] [--state probe.json] [--seconds 60]
using System.Text.Json;
using MXLink;

string? Arg(string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
var host = Arg("--host") ?? "127.0.0.1";
var port = Wire.TcpPort;
var statePath = Arg("--state") ?? Path.Combine(Path.GetTempPath(), "mxlink-probe.json");
var seconds = double.Parse(Arg("--seconds") ?? "60");
void Log(string s) => Console.WriteLine($"[probe] {s}");

if (args.Contains("--discover"))
{
    var found = await Discovery.FindMacAsync(TimeSpan.FromSeconds(2));
    Log(found is null ? "discovery: no reply" : $"discovery: {found.Name} at {found.Host}:{found.Port}");
    if (found is not null) { host = found.Host; port = found.Port; }
}

var pins = new FilePins(statePath);
using var session = new Session(pins.Identity, pins) { ScreenWidth = 2560, ScreenHeight = 1440 };
double x = 0, y = 0; var active = false; var moves = 0;
session.StateChanged += s =>
{
    Log($"state: {s}");
    if (s == SessionState.Pairing) { Log($"pairing code {session.PairingCode}"); session.ConfirmPairing(); }
};
session.MessageReceived += m =>
{
    switch (m)
    {
        case Enter e: x = e.X * 2560; y = e.Y * 1440; active = true; moves = 0; Log($"enter at {x:F0},{y:F0}"); break;
        case Move mv when active:
            x += mv.Dx; y = Math.Clamp(y + mv.Dy, 0, 1439);
            if (++moves % 25 == 1) Log($"pointer {x:F0},{y:F0}");
            if (x < 0) { active = false; Log($"left edge at y {y:F0} → returned"); session.Send(new Returned((float)(y / 1440))); }
            break;
        case MXLink.Clipboard c: Log(c.Kind == 1 ? $"clipboard text: {System.Text.Encoding.UTF8.GetString(c.Data)}" : $"clipboard image {c.Data.Length} bytes"); break;
        default: Log(m.ToString()); break;
    }
};
Log($"connecting to {host}:{port} as {pins.Identity.Name}");
var run = session.RunAsync(host, port);
await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(seconds)));
session.Close("probe finished");
Log($"closed: {session.CloseReason}");

sealed class FilePins : IPinStore
{
    private readonly string _path;
    private readonly Dictionary<string, string> _json;
    public Identity Identity { get; }

    public FilePins(string path)
    {
        _path = path;
        try { _json = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? []; } catch { _json = []; }
        Identity = _json.TryGetValue("identity", out var s) && Identity.Import(Convert.FromBase64String(s), "C# Probe") is { } id
            ? id : Identity.Create("C# Probe");
        _json["identity"] = Convert.ToBase64String(Identity.Export());
        Save();
    }

    private void Save() => File.WriteAllText(_path, JsonSerializer.Serialize(_json));
    public byte[]? KeyFor(byte[] peerId) => _json.TryGetValue("peer." + Convert.ToHexString(peerId), out var k) ? Convert.FromBase64String(k) : null;
    public void Pin(byte[] peerId, string name, byte[] key) { _json["peer." + Convert.ToHexString(peerId)] = Convert.ToBase64String(key); Save(); }
    public byte[]? AnyPinnedKey => _json.FirstOrDefault(p => p.Key.StartsWith("peer.")).Value is { } v ? Convert.FromBase64String(v) : null;
}
