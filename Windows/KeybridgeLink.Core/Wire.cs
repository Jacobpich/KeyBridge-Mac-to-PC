// Crossover wire protocol, version 1. Mirrors Sources/Keybridge/Crossover/Wire.swift;
// keep the two in step. See that file for the full description.
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace KeybridgeLink;

public static class Wire
{
    public static readonly byte[] Magic = "MXC1"u8.ToArray();
    public const byte Version = 1;
    public const int TcpPort = 47820;
    public const int DiscoveryPort = 47821;
    public const int MaxFrame = 32 << 20;
    public const int MaxClipboard = 20 << 20;
    public const byte RoleMac = 0x4D, RolePC = 0x50;
    /// What this version understands, sent in the hello. A side only sends the newer messages when
    /// the other said it understands them, so mixed versions keep working.
    public const uint FeatureFiles = 1 << 0;    // 0x50–0x54: copied and dragged files
    public const uint FeatureLayout = 1 << 1;   // 0x17: the PC can sit on any side of the Mac
    public const uint Features = FeatureFiles | FeatureLayout;
}

public sealed class WireException(string message) : Exception(message);

public sealed class ByteWriter
{
    private readonly MemoryStream _ms = new();
    public ByteWriter U8(byte v) { _ms.WriteByte(v); return this; }
    public ByteWriter U16(ushort v) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16LittleEndian(b, v); _ms.Write(b); return this; }
    public ByteWriter U32(uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(b, v); _ms.Write(b); return this; }
    public ByteWriter U64(ulong v) { Span<byte> b = stackalloc byte[8]; BinaryPrimitives.WriteUInt64LittleEndian(b, v); _ms.Write(b); return this; }
    public ByteWriter F32(float v) => U32(BitConverter.SingleToUInt32Bits(v));
    public ByteWriter Raw(ReadOnlySpan<byte> d) { _ms.Write(d); return this; }
    public ByteWriter Str(string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        if (bytes.Length > 200) bytes = bytes[..200];
        U16((ushort)bytes.Length); return Raw(bytes);
    }
    /// A string of up to 65,535 UTF-8 bytes (file paths), never cut short.
    public ByteWriter LongStr(string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        if (bytes.Length > 65535) bytes = bytes[..65535];
        U16((ushort)bytes.Length); return Raw(bytes);
    }
    public byte[] ToArray() => _ms.ToArray();
}

public sealed class ByteReader(byte[] data)
{
    private int _offset;
    public int Remaining => data.Length - _offset;
    public byte[] Raw(int n)
    {
        if (n < 0 || Remaining < n) throw new WireException("message too short");
        var r = data.AsSpan(_offset, n).ToArray(); _offset += n; return r;
    }
    public byte U8() => Raw(1)[0];
    public ushort U16() => BinaryPrimitives.ReadUInt16LittleEndian(Raw(2));
    public uint U32() => BinaryPrimitives.ReadUInt32LittleEndian(Raw(4));
    public ulong U64() => BinaryPrimitives.ReadUInt64LittleEndian(Raw(8));
    public float F32() => BitConverter.UInt32BitsToSingle(U32());
    public string Str() => Encoding.UTF8.GetString(Raw(U16()));
    public byte[] Rest() => Raw(Remaining);
}

public sealed record Hello(byte Role, byte[] Id, string Name, byte[] StaticKey, byte[] EphemeralKey,
                           byte[] PeerFingerprint, ushort ScreenWidth, ushort ScreenHeight, uint Features = 0)
{
    public byte[] Encode() => new ByteWriter().Raw(Wire.Magic).U8(Wire.Version).U8(Role).Raw(Id).Str(Name)
        .Raw(StaticKey).Raw(EphemeralKey).Raw(PeerFingerprint).U16(ScreenWidth).U16(ScreenHeight).U32(Features).ToArray();

    public static Hello Decode(byte[] data)
    {
        var r = new ByteReader(data);
        if (!r.Raw(4).AsSpan().SequenceEqual(Wire.Magic)) throw new WireException("not a Keybridge connection");
        if (r.U8() != Wire.Version) throw new WireException("different Crossover version");
        var role = r.U8();
        if (role != Wire.RoleMac && role != Wire.RolePC) throw new WireException("unexpected role");
        var h = new Hello(role, r.Raw(16), r.Str(), r.Raw(65), r.Raw(65), r.Raw(32), r.U16(), r.U16());
        // Versions before file sharing end here (no feature bits).
        return r.Remaining >= 4 ? h with { Features = r.U32() } : h;
    }
}

/// Messages inside the encrypted frames.
public abstract record Msg
{
    public abstract byte[] Encode();

    public static Msg Decode(byte[] data)
    {
        var r = new ByteReader(data);
        var type = r.U8();
        return type switch
        {
            0x01 => new Heartbeat(),
            0x02 => new PairConfirm(),
            0x10 => new Enter(r.F32(), r.F32()),
            0x11 => new Move(r.F32(), r.F32()),
            0x12 => new Button(r.U8(), r.U8() != 0),
            0x13 => new Scroll(r.F32(), r.F32()),
            0x14 => DecodeKey(r),
            0x15 => new VKey(r.U16(), r.U8() != 0),
            0x16 => new Leave(),
            0x17 => new Layout(r.U8()),
            0x20 => new Returned(r.F32()),
            0x30 => new Clipboard(r.U8(), r.Rest()),
            0x40 => new Screen(r.U16(), r.U16()),
            0x50 => FilesOffer.Decode(r),
            0x51 => new FileData(r.U32(), r.U32(), r.Rest()),
            0x52 => new FilesDone(r.U32(), r.U8() != 0),
            0x53 => new FilesCancel(r.U32()),
            0x54 => new DragEnded(r.U32(), r.U8() != 0),
            _ => new Unknown(type),   // from a newer version: ignored
        };
    }

    private static Key DecodeKey(ByteReader r)
    {
        var scan = r.U16(); var flags = r.U8();
        return new Key(scan, (flags & 1) != 0, (flags & 2) != 0);
    }
}

public sealed record Heartbeat : Msg { public override byte[] Encode() => [0x01]; }
public sealed record PairConfirm : Msg { public override byte[] Encode() => [0x02]; }
/// Pointer enters the PC at this fraction of its screen.
public sealed record Enter(float X, float Y) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x10).F32(X).F32(Y).ToArray(); }
/// Pixels on the PC screen.
public sealed record Move(float Dx, float Dy) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x11).F32(Dx).F32(Dy).ToArray(); }
/// 0 left, 1 right, 2 middle, 3 back, 4 forward.
public sealed record Button(byte Which, bool Down) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x12).U8(Which).U8((byte)(Down ? 1 : 0)).ToArray(); }
/// Wheel notches; positive is up / right.
public sealed record Scroll(float Vertical, float Horizontal) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x13).F32(Vertical).F32(Horizontal).ToArray(); }
/// Windows set-1 scan code.
public sealed record Key(ushort Scan, bool Extended, bool Down) : Msg
{
    public override byte[] Encode() => new ByteWriter().U8(0x14).U16(Scan).U8((byte)((Extended ? 1 : 0) | (Down ? 2 : 0))).ToArray();
}
/// Windows virtual key (media keys).
public sealed record VKey(ushort Vk, bool Down) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x15).U16(Vk).U8((byte)(Down ? 1 : 0)).ToArray(); }
public sealed record Leave : Msg { public override byte[] Encode() => [0x16]; }
/// Mac→PC: the PC screen's edge that faces the Mac (FeatureLayout).
public sealed record Layout(byte Edge) : Msg
{
    public const byte Left = 0, Right = 1, Top = 2, Bottom = 3;
    public override byte[] Encode() => new ByteWriter().U8(0x17).U8(Edge).ToArray();
}
/// The pointer left by the edge facing the Mac, at this fraction along it (top→bottom or left→right).
public sealed record Returned(float Y) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x20).F32(Y).ToArray(); }
/// A message from a newer version.
public sealed record Unknown(byte Type) : Msg { public override byte[] Encode() => [Type]; }
/// 1 = UTF-8 text, 2 = PNG.
public sealed record Clipboard(byte Kind, byte[] Data) : Msg
{
    public const byte Text = 1, Png = 2;
    public override byte[] Encode() => new ByteWriter().U8(0x30).U8(Kind).Raw(Data).ToArray();
}
public sealed record Screen(ushort Width, ushort Height) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x40).U16(Width).U16(Height).ToArray(); }

/// One file or folder in a transfer. Path is relative with "/" between folders; the transfer's
/// top-level items are the entries without a "/".
public sealed record FileEntry(string Path, ulong Size, bool IsDirectory);

public static class TransferPurpose { public const byte Clipboard = 1, Drag = 2; }

/// File transfers, both ways: the offer, then each file's bytes in order, then done.
public sealed record FilesOffer(uint Id, byte Purpose, FileEntry[] Entries) : Msg
{
    public override byte[] Encode()
    {
        var w = new ByteWriter().U8(0x50).U32(Id).U8(Purpose).U32((uint)Entries.Length);
        foreach (var e in Entries) w.LongStr(e.Path).U64(e.Size).U8((byte)(e.IsDirectory ? 1 : 0));
        return w.ToArray();
    }

    internal static FilesOffer Decode(ByteReader r)
    {
        var id = r.U32(); var purpose = r.U8(); var count = r.U32();
        if (count > 1_000_000) throw new WireException("too many files");
        var entries = new FileEntry[count];
        for (var i = 0; i < count; i++) entries[i] = new FileEntry(r.Str(), r.U64(), r.U8() != 0);
        return new FilesOffer(id, purpose, entries);
    }
}

public sealed record FileData(uint Id, uint Index, byte[] Data) : Msg
{
    public override byte[] Encode() => new ByteWriter().U8(0x51).U32(Id).U32(Index).Raw(Data).ToArray();
}

public sealed record FilesDone(uint Id, bool Complete) : Msg
{
    public override byte[] Encode() => new ByteWriter().U8(0x52).U32(Id).U8((byte)(Complete ? 1 : 0)).ToArray();
}

/// Receiver → sender: stop sending this transfer.
public sealed record FilesCancel(uint Id) : Msg { public override byte[] Encode() => new ByteWriter().U8(0x53).U32(Id).ToArray(); }

/// Mac → PC: a drag that started on the PC finished on the Mac.
public sealed record DragEnded(uint Id, bool Dropped) : Msg
{
    public override byte[] Encode() => new ByteWriter().U8(0x54).U32(Id).U8((byte)(Dropped ? 1 : 0)).ToArray();
}

public static class WireCrypto
{
    public static byte[] Fingerprint(byte[] key) => SHA256.HashData(key);

    private static byte[] Concat(params byte[][] parts)
    {
        var all = new byte[parts.Sum(p => p.Length)];
        var at = 0;
        foreach (var p in parts) { p.CopyTo(all, at); at += p.Length; }
        return all;
    }

    public static string PairingCode(byte[] macKey, byte[] pcKey)
    {
        var h = SHA256.HashData(Concat("MXC1 pair"u8.ToArray(), macKey, pcKey));
        return (BinaryPrimitives.ReadUInt32BigEndian(h) % 1_000_000).ToString("D6");
    }

    public static ECDiffieHellman NewKey() => ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    /// 65-byte X9.63 uncompressed public key (0x04 || X || Y), as CryptoKit uses.
    public static byte[] PublicKey(ECDiffieHellman key)
    {
        var p = key.ExportParameters(false);
        return [0x04, .. p.Q.X!, .. p.Q.Y!];
    }

    public static ECDiffieHellman ImportPublic(byte[] x963)
    {
        if (x963.Length != 65 || x963[0] != 0x04) throw new WireException("bad public key");
        return ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = x963[1..33], Y = x963[33..65] },
        });
    }

    /// Returns (PC→Mac key, Mac→PC key).
    public static (byte[] PcToMac, byte[] MacToPc) SessionKeys(ECDiffieHellman myStatic, ECDiffieHellman myEphemeral,
        byte[] peerStatic, byte[] peerEphemeral, byte[] pcHello, byte[] macHello)
    {
        using var ps = ImportPublic(peerStatic);
        using var pe = ImportPublic(peerEphemeral);
        var ee = myEphemeral.DeriveRawSecretAgreement(pe.PublicKey);
        var ss = myStatic.DeriveRawSecretAgreement(ps.PublicKey);
        var salt = SHA256.HashData(Concat(pcHello, macHello));
        var okm = HKDF.DeriveKey(HashAlgorithmName.SHA256, [.. ee, .. ss], 64, salt, "MXC1 session"u8.ToArray());
        return (okm[..32], okm[32..]);
    }

    private static byte[] Nonce(ulong counter)
    {
        var n = new byte[12];
        BinaryPrimitives.WriteUInt64LittleEndian(n.AsSpan(4), counter);
        return n;
    }

    public static byte[] Seal(byte[] plain, byte[] key, ulong counter)
    {
        using var gcm = new AesGcm(key, 16);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        gcm.Encrypt(Nonce(counter), plain, cipher, tag);
        return [.. cipher, .. tag];
    }

    public static byte[] Open(byte[] body, byte[] key, ulong counter)
    {
        if (body.Length < 16) throw new WireException("message failed authentication");
        using var gcm = new AesGcm(key, 16);
        var plain = new byte[body.Length - 16];
        try { gcm.Decrypt(Nonce(counter), body.AsSpan(0, body.Length - 16), body.AsSpan(body.Length - 16), plain); }
        catch (CryptographicException) { throw new WireException("message failed authentication"); }
        return plain;
    }
}
