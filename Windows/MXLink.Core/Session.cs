// One encrypted Crossover connection from the PC to the Mac. Mirrors Session.swift.
using System.Net.Sockets;
using System.Security.Cryptography;

namespace MXLink;

/// The PC's long-term identity.
public sealed class Identity : IDisposable
{
    public byte[] Id { get; }
    public string Name { get; }
    public ECDiffieHellman Key { get; }
    public byte[] PublicKey { get; }

    private Identity(byte[] id, string name, ECDiffieHellman key)
    {
        Id = id; Name = name; Key = key; PublicKey = WireCrypto.PublicKey(key);
    }

    public static Identity Create(string name) => new(RandomNumberGenerator.GetBytes(16), name, WireCrypto.NewKey());

    /// 16-byte id + the private key (DER, SEC1). Protect it before saving.
    public byte[] Export() => [.. Id, .. Key.ExportECPrivateKey()];

    public static Identity? Import(byte[] stored, string name)
    {
        if (stored.Length <= 16) return null;
        try
        {
            var key = ECDiffieHellman.Create();
            key.ImportECPrivateKey(stored.AsSpan(16), out _);
            return new Identity(stored[..16], name, key);
        }
        catch (CryptographicException) { return null; }
    }

    public void Dispose() => Key.Dispose();
}

/// Paired Macs: their id → static public key.
public interface IPinStore
{
    byte[]? KeyFor(byte[] peerId);
    void Pin(byte[] peerId, string name, byte[] key);
    byte[]? AnyPinnedKey { get; }
}

public enum SessionState { Connecting, Handshaking, Pairing, WaitingForPeer, Trusted, Closed }

public sealed class Session : IDisposable
{
    private readonly Identity _identity;
    private readonly IPinStore _pins;
    private readonly ECDiffieHellman _ephemeral = WireCrypto.NewKey();
    private readonly object _writeLock = new();
    private readonly CancellationTokenSource _cts = new();
    private NetworkStream? _stream;
    private TcpClient? _client;
    private byte[] _myHello = [];
    private byte[]? _sendKey, _receiveKey;
    private ulong _sendCounter, _receiveCounter;
    private bool _localTrust, _remoteTrust;
    private long _lastHeardTicks = Environment.TickCount64;

    public ushort ScreenWidth { get; set; }
    public ushort ScreenHeight { get; set; }
    public SessionState State { get; private set; } = SessionState.Connecting;
    public Hello? Peer { get; private set; }
    public string PeerName => Peer?.Name ?? "Mac";
    public string? PairingCode { get; private set; }
    public string? CloseReason { get; private set; }

    /// Raised on the network thread.
    public event Action<SessionState>? StateChanged;
    /// Raised on the network thread, in order.
    public event Action<Msg>? MessageReceived;

    public Session(Identity identity, IPinStore pins) { _identity = identity; _pins = pins; }

    /// Connects and runs until the connection ends. Never throws; see CloseReason.
    public async Task RunAsync(string host, int port)
    {
        try
        {
            _client = new TcpClient { NoDelay = true };
            using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            using (var linked = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, _cts.Token))
                await _client.ConnectAsync(host, port, linked.Token);
            _stream = _client.GetStream();
            SetState(SessionState.Handshaking);
            SendHello();
            _lastHeardTicks = Environment.TickCount64;
            var heartbeat = Task.Run(HeartbeatLoop);
            await ReadLoop();
            await heartbeat;
        }
        catch (Exception e) when (e is IOException or SocketException or WireException or OperationCanceledException or ObjectDisposedException or CryptographicException)
        {
            CloseReason ??= e.Message;
        }
        finally { Close(CloseReason ?? "connection closed"); }
    }

    public void Close(string reason)
    {
        if (State == SessionState.Closed) return;
        CloseReason ??= reason;
        _cts.Cancel();
        try { _client?.Close(); } catch { }
        SetState(SessionState.Closed);
    }

    /// The user checked that both screens show the same code.
    public void ConfirmPairing()
    {
        if (State != SessionState.Pairing || Peer is null) return;
        _pins.Pin(Peer.Id, Peer.Name, Peer.StaticKey);
        _localTrust = true;
        Send(new PairConfirm(), force: true);
        UpdateTrust();
    }

    public void Send(Msg message) => Send(message, force: false);

    private void Send(Msg message, bool force)
    {
        lock (_writeLock)
        {
            if (_sendKey is null || _stream is null || (!force && State != SessionState.Trusted)) return;
            var body = WireCrypto.Seal(message.Encode(), _sendKey, _sendCounter++);
            WriteFrame(body);
        }
    }

    private void WriteFrame(byte[] body)
    {
        var frame = new ByteWriter().U32((uint)body.Length).Raw(body).ToArray();
        try { _stream!.Write(frame); } catch (Exception e) when (e is IOException or ObjectDisposedException) { Close(e.Message); }
    }

    private void SendHello()
    {
        var pinned = _pins.AnyPinnedKey is { } k ? WireCrypto.Fingerprint(k) : new byte[32];
        var hello = new Hello(Wire.RolePC, _identity.Id, _identity.Name, _identity.PublicKey,
                              WireCrypto.PublicKey(_ephemeral), pinned, ScreenWidth, ScreenHeight);
        _myHello = hello.Encode();
        lock (_writeLock) WriteFrame(_myHello);
    }

    private async Task HeartbeatLoop()
    {
        while (!_cts.IsCancellationRequested)
        {
            try { await Task.Delay(250, _cts.Token); } catch (OperationCanceledException) { return; }
            var silent = (Environment.TickCount64 - Interlocked.Read(ref _lastHeardTicks)) / 1000.0;
            if (_sendKey is null) { if (silent > 5) Close("no hello"); continue; }
            Send(new Heartbeat(), force: true);
            // Waiting on a person to confirm the code can take a while; otherwise 1.5 s of
            // silence means the Mac is gone.
            if (silent > (State == SessionState.Trusted ? 1.5 : 120)) Close("timed out");
        }
    }

    private async Task ReadLoop()
    {
        var header = new byte[4];
        while (!_cts.IsCancellationRequested)
        {
            await _stream!.ReadExactlyAsync(header, _cts.Token);
            var length = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(header);
            if (length < 0 || length > Wire.MaxFrame) throw new WireException("frame too large");
            var body = new byte[length];
            await _stream.ReadExactlyAsync(body, _cts.Token);
            Interlocked.Exchange(ref _lastHeardTicks, Environment.TickCount64);
            Frame(body);
        }
    }

    private void Frame(byte[] body)
    {
        if (_receiveKey is null) { OnHello(body); return; }
        var message = Msg.Decode(WireCrypto.Open(body, _receiveKey, _receiveCounter++));
        switch (message)
        {
            case Heartbeat: return;
            case PairConfirm: _remoteTrust = true; UpdateTrust(); return;
            default:
                if (State == SessionState.Trusted) MessageReceived?.Invoke(message);
                return;
        }
    }

    private void OnHello(byte[] body)
    {
        var h = Hello.Decode(body);
        if (h.Role != Wire.RoleMac) throw new WireException("unexpected role");
        Peer = h;
        var (p2m, m2p) = WireCrypto.SessionKeys(_identity.Key, _ephemeral, h.StaticKey, h.EphemeralKey, _myHello, body);
        lock (_writeLock) { _sendKey = p2m; _receiveKey = m2p; }
        _localTrust = _pins.KeyFor(h.Id) is { } pinned && pinned.AsSpan().SequenceEqual(h.StaticKey);
        _remoteTrust = h.PeerFingerprint.AsSpan().SequenceEqual(WireCrypto.Fingerprint(_identity.PublicKey));
        if (_localTrust) Send(new PairConfirm(), force: true);
        UpdateTrust();
    }

    private void UpdateTrust()
    {
        if (Peer is null) return;
        if (_localTrust && _remoteTrust) SetState(SessionState.Trusted);
        else if (!_localTrust)
        {
            PairingCode = WireCrypto.PairingCode(Peer.StaticKey, _identity.PublicKey);
            SetState(SessionState.Pairing);
        }
        else SetState(SessionState.WaitingForPeer);
    }

    private void SetState(SessionState s)
    {
        if (State == s) return;
        State = s;
        StateChanged?.Invoke(s);
    }

    public void Dispose()
    {
        Close("disposed");
        _ephemeral.Dispose();
        _cts.Dispose();
    }
}
