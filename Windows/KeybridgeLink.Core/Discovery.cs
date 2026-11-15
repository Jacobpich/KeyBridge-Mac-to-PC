using System.Net;
using System.Net.Sockets;
using System.Text;

namespace KeybridgeLink;

/// Finds Keybridge on the local network: broadcasts "MXC1?" on UDP 47821 and waits for
/// "MXC1!" + u16 TCP port + name from the Mac.
public static class Discovery
{
    public sealed record Found(string Host, int Port, string Name);

    public static async Task<Found?> FindMacAsync(TimeSpan timeout, CancellationToken ct = default)
    {
        // First a broadcast; if nothing answers (some networks drop broadcasts), ask every
        // address on this PC's local subnets directly.
        return await AskAsync([IPAddress.Broadcast], timeout, ct)
            ?? await AskAsync(SubnetHosts().ToList(), timeout, ct);
    }

    /// Every host address on this machine's IPv4 networks (only for subnets of /22 or smaller).
    public static IEnumerable<IPAddress> SubnetHosts()
    {
        foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
            foreach (var ua in nic.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.PrefixLength < 22 || ua.PrefixLength > 30) continue;
                var ip = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(ua.Address.GetAddressBytes());
                var mask = uint.MaxValue << (32 - ua.PrefixLength);
                var network = ip & mask;
                var count = ~mask;
                for (uint i = 1; i < count; i++)
                {
                    var host = network | i;
                    if (host == ip) continue;
                    var bytes = new byte[4];
                    System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bytes, host);
                    yield return new IPAddress(bytes);
                }
            }
        }
    }

    private static async Task<Found?> AskAsync(IReadOnlyList<IPAddress> targets, TimeSpan timeout, CancellationToken ct)
    {
        if (targets.Count == 0) return null;
        using var udp = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        var ask = "MXC1?"u8.ToArray();
        foreach (var t in targets)
        {
            try { await udp.SendAsync(ask, new IPEndPoint(t, Wire.DiscoveryPort), ct); }
            catch (SocketException) { }
        }
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(timeout);
        try
        {
            while (true)
            {
                var reply = await udp.ReceiveAsync(limit.Token);
                var d = reply.Buffer;
                if (d.Length < 7 || Encoding.ASCII.GetString(d, 0, 5) != "MXC1!") continue;
                var r = new ByteReader(d[5..]);
                var port = r.U16();
                var name = r.Remaining >= 2 ? r.Str() : "Mac";
                return new Found(reply.RemoteEndPoint.Address.ToString(), port, name);
            }
        }
        catch (OperationCanceledException) { return null; }
        catch (SocketException) { return null; }
    }
}
