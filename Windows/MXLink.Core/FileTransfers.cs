namespace MXLink;

/// Sends and receives files over the Crossover link (copied or dragged files). Mirrors
/// FileTransfers.swift: an offer listing every file and folder, then each file's bytes in order in
/// 256 KB chunks, then "done".
public sealed class FileTransfers
{
    public const int ChunkSize = 256 * 1024;

    /// Received files live here until they're pasted or dropped; cleared after a week.
    public static readonly string Folder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MX Control for PC", "Transfers");

    /// Sends one message (blocking until the connection takes it). Returns false with no link.
    public Func<Msg, bool>? Send;
    /// A transfer was offered to this PC; it's already being received into its folder.
    public event Action<IncomingTransfer>? Offered;
    public Action<string>? Log;

    private readonly object _lock = new();
    private readonly Dictionary<uint, IncomingTransfer> _incoming = [];
    private readonly Dictionary<uint, CancellationTokenSource> _outgoing = [];
    private readonly Dictionary<uint, byte> _outgoingPurpose = [];
    private uint _nextId = (uint)Random.Shared.Next(0x40000000, 0x7FFFFFFF);

    public FileTransfers() => Sweep();

    // ---- Sending

    /// Starts sending these files and folders. Returns the transfer id, or null if there's nothing
    /// to send or no link.
    public uint? SendFiles(IReadOnlyList<string> paths, byte purpose, ulong maxBytes = ulong.MaxValue)
    {
        var (entries, sources) = List(paths);
        var send = Send;
        if (entries.Count == 0 || send is null) return null;
        var total = entries.Aggregate(0UL, (sum, e) => sum + e.Size);
        if (total > maxBytes) { Log?.Invoke($"not sending {total} bytes for purpose {purpose}: over the limit"); return null; }
        uint id; CancellationTokenSource cts;
        lock (_lock)
        {
            foreach (var (old, p) in _outgoingPurpose.ToArray())
                if (p == purpose) { _outgoing[old].Cancel(); _outgoing.Remove(old); _outgoingPurpose.Remove(old); }
            id = ++_nextId;
            cts = new CancellationTokenSource();
            _outgoing[id] = cts; _outgoingPurpose[id] = purpose;
        }
        if (!send(new FilesOffer(id, purpose, [.. entries]))) { Forget(id); return null; }
        Log?.Invoke($"sending {entries.Count} item(s) for purpose {purpose}");
        _ = Task.Run(() =>
        {
            var ok = Run(id, sources, send, cts.Token);
            send(new FilesDone(id, ok));
            Forget(id);
            Log?.Invoke($"sent transfer {id}: {(ok ? "complete" : "stopped")}");
        });
        return id;
    }

    public void CancelOutgoing(uint id)
    {
        lock (_lock) if (_outgoing.TryGetValue(id, out var cts)) cts.Cancel();
    }

    private void Forget(uint id)
    {
        lock (_lock) { _outgoing.Remove(id); _outgoingPurpose.Remove(id); }
    }

    private static bool Run(uint id, List<string?> sources, Func<Msg, bool> send, CancellationToken ct)
    {
        var buffer = new byte[ChunkSize];
        for (var i = 0; i < sources.Count; i++)
        {
            if (sources[i] is not { } path) continue;
            try
            {
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                int n;
                while ((n = fs.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (ct.IsCancellationRequested) return false;
                    if (!send(new FileData(id, (uint)i, buffer[..n]))) return false;
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        }
        return !ct.IsCancellationRequested;
    }

    /// Every file and folder under `paths`, as relative entries, plus the file each entry reads from.
    private static (List<FileEntry>, List<string?>) List(IReadOnlyList<string> paths)
    {
        var entries = new List<FileEntry>(); var sources = new List<string?>();
        foreach (var top in paths)
        {
            var name = Path.GetFileName(top.TrimEnd('\\', '/'));
            if (File.Exists(top))
            {
                entries.Add(new FileEntry(name, (ulong)new FileInfo(top).Length, false)); sources.Add(top);
            }
            else if (Directory.Exists(top))
            {
                entries.Add(new FileEntry(name, 0, true)); sources.Add(null);
                var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true,
                                                       AttributesToSkip = FileAttributes.ReparsePoint };
                foreach (var dir in Directory.EnumerateDirectories(top, "*", options))
                {
                    entries.Add(new FileEntry(name + "/" + Path.GetRelativePath(top, dir).Replace('\\', '/'), 0, true)); sources.Add(null);
                }
                foreach (var file in Directory.EnumerateFiles(top, "*", options))
                {
                    entries.Add(new FileEntry(name + "/" + Path.GetRelativePath(top, file).Replace('\\', '/'),
                                              (ulong)new FileInfo(file).Length, false));
                    sources.Add(file);
                }
            }
        }
        return (entries, sources);
    }

    // ---- Receiving (called on the network thread)

    public void Received(Msg m)
    {
        switch (m)
        {
            case FilesOffer offer:
            {
                IncomingTransfer? t;
                lock (_lock)
                {
                    foreach (var (old, it) in _incoming.ToArray())
                        if (it.Purpose == offer.Purpose) { it.Finish(false); _incoming.Remove(old); }
                    t = IncomingTransfer.Create(offer);
                    if (t is not null) _incoming[offer.Id] = t;
                }
                if (t is null) { Send?.Invoke(new FilesCancel(offer.Id)); return; }
                Log?.Invoke($"receiving {offer.Entries.Length} item(s) for purpose {offer.Purpose}");
                Offered?.Invoke(t);
                break;
            }
            case FileData data:
            {
                IncomingTransfer? t;
                lock (_lock) _incoming.TryGetValue(data.Id, out t);
                t?.Write((int)data.Index, data.Data);
                break;
            }
            case FilesDone done:
            {
                IncomingTransfer? t;
                lock (_lock) { _incoming.Remove(done.Id, out t); }
                t?.Finish(done.Complete);
                Log?.Invoke($"received transfer {done.Id}: {(done.Complete ? "complete" : "stopped")}");
                break;
            }
            case FilesCancel cancel:
                CancelOutgoing(cancel.Id);
                break;
        }
    }

    /// Stops receiving `id` and tells the sender.
    public void CancelIncoming(uint id)
    {
        IncomingTransfer? t;
        lock (_lock) _incoming.Remove(id, out t);
        if (t is null) return;
        t.Finish(false);
        Send?.Invoke(new FilesCancel(id));
    }

    /// The link went away: everything in flight stops.
    public void Reset()
    {
        lock (_lock)
        {
            foreach (var cts in _outgoing.Values) cts.Cancel();
            _outgoing.Clear(); _outgoingPurpose.Clear();
            foreach (var t in _incoming.Values) t.Finish(false);
            _incoming.Clear();
        }
    }

    private static void Sweep()
    {
        try
        {
            if (!Directory.Exists(Folder)) return;
            foreach (var dir in Directory.GetDirectories(Folder))
                if (Directory.GetCreationTimeUtc(dir) < DateTime.UtcNow.AddDays(-7))
                    try { Directory.Delete(dir, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        catch (IOException) { }
    }
}

/// A transfer being received into its own folder under FileTransfers.Folder.
public sealed class IncomingTransfer
{
    public uint Id { get; }
    public byte Purpose { get; }
    public FileEntry[] Entries { get; }
    public string Folder { get; }
    /// The top-level files and folders. They exist from the start, empty until the data arrives.
    public string[] TopLevel { get; }
    /// Completes with true once every file is here, false if the transfer stopped.
    public Task<bool> Done => _done.Task;

    private readonly string?[] _paths;
    private readonly TaskCompletionSource<bool> _done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _lock = new();
    private FileStream? _stream;
    private int _current = -1;
    private bool _failed, _finished;

    private IncomingTransfer(FilesOffer offer, string folder, string?[] paths, string[] topLevel)
    {
        Id = offer.Id; Purpose = offer.Purpose; Entries = offer.Entries; Folder = folder; _paths = paths; TopLevel = topLevel;
    }

    internal static IncomingTransfer? Create(FilesOffer offer)
    {
        var folder = Path.Combine(FileTransfers.Folder, $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{offer.Id}");
        var paths = new string?[offer.Entries.Length];
        var top = new List<string>();
        try
        {
            Directory.CreateDirectory(folder);
            for (var i = 0; i < offer.Entries.Length; i++)
            {
                var e = offer.Entries[i];
                if (Safe(e.Path) is not { } rel) return null;
                var full = Path.Combine(folder, rel);
                if (e.IsDirectory) Directory.CreateDirectory(full);
                else
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(full)!);
                    File.Create(full).Dispose();
                    paths[i] = full;
                }
                if (!rel.Contains('\\')) top.Add(full);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        return new IncomingTransfer(offer, folder, paths, [.. top]);
    }

    /// A relative Windows path that stays inside the transfer folder, with characters Windows
    /// doesn't allow in names replaced; or null.
    private static string? Safe(string path)
    {
        var bad = Path.GetInvalidFileNameChars();
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => new string(p.Select(c => bad.Contains(c) ? '_' : c).ToArray()).TrimEnd('.', ' '))
            .ToArray();
        if (parts.Length == 0 || parts.Any(p => p is "" or "." or "..")) return null;
        return string.Join('\\', parts);
    }

    internal void Write(int index, byte[] data)
    {
        lock (_lock)
        {
            if (_failed || _finished || index < 0 || index >= _paths.Length || _paths[index] is not { } path) { _failed = true; return; }
            try
            {
                if (index != _current)
                {
                    _stream?.Dispose();
                    _stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                    _current = index;
                }
                _stream!.Write(data);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { _failed = true; }
        }
    }

    internal void Finish(bool ok)
    {
        lock (_lock)
        {
            if (_finished) return;
            _finished = true;
            _stream?.Dispose(); _stream = null;
        }
        var complete = ok && !_failed;
        if (!complete) try { Directory.Delete(Folder, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        _done.TrySetResult(complete);
    }
}
