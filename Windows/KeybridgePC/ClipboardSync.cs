using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace KeybridgePC;

/// What was copied: text or an image to send directly, or files to send as a transfer.
sealed record ClipPayload(KeybridgeLink.Clipboard? Data, string[]? Files);

/// The PC side of clipboard sharing: text, an image as PNG, or copied files and folders.
/// Passwords copied from a password manager stay on the PC. Must be used on the UI (STA) thread.
sealed class ClipboardSync
{
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    private uint? _lastSent;                 // null: the first crossing sends whatever is already copied
    private uint _lastWritten = uint.MaxValue;

    /// Formats Windows password managers use to say "don't sync or keep this".
    private static readonly string[] SecretMarkers =
        ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"];

    private static readonly string[] ImageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp"];

    public static uint SequenceNumber => GetClipboardSequenceNumber();

    /// The clipboard, if it changed since it was last sent or received.
    public ClipPayload? PayloadIfChanged()
    {
        var p = Read();
        return p switch { null => null, KeybridgeLink.Clipboard c => new ClipPayload(c, null), string[] f => new ClipPayload(null, f), _ => null };
    }

    private object? Read()
    {
        var seq = GetClipboardSequenceNumber();
        if (seq == _lastSent || seq == _lastWritten) return null;
        try
        {
            var data = Clipboard.GetDataObject();
            _lastSent = seq;
            if (data is null) return null;
            var formats = data.GetFormats(false);
            if (SecretMarkers.Any(formats.Contains)) return null;
            if (data.GetData("CanUploadToCloudClipboard") is MemoryStream cloud && cloud.Length >= 4 &&
                BitConverter.ToInt32(cloud.ToArray(), 0) == 0) return null;

            // Files or folders copied in File Explorer.
            if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files)
                return files;
            if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string { Length: > 0 } text)
                return Limit(KeybridgeLink.Clipboard.Text, System.Text.Encoding.UTF8.GetBytes(text));
            // Browsers and Snipping Tool put a real PNG on the clipboard (keeps transparency).
            if (data.GetData("PNG") is MemoryStream pngStream) return Limit(KeybridgeLink.Clipboard.Png, pngStream.ToArray());
            if (data.GetDataPresent(DataFormats.Bitmap) && data.GetData(DataFormats.Bitmap) is Image image)
            {
                using (image) return Limit(KeybridgeLink.Clipboard.Png, ToPng(image));
            }
        }
        catch (ExternalException) { _lastSent = null; }   // another app has the clipboard open: try again next time
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException) { }
        return null;
    }

    public void Write(KeybridgeLink.Clipboard clip)
    {
        try
        {
            var data = new DataObject();
            if (clip.Kind == KeybridgeLink.Clipboard.Text)
            {
                data.SetText(System.Text.Encoding.UTF8.GetString(clip.Data), TextDataFormat.UnicodeText);
            }
            else if (clip.Kind == KeybridgeLink.Clipboard.Png)
            {
                data.SetData("PNG", false, new MemoryStream(clip.Data));
                using var image = Image.FromStream(new MemoryStream(clip.Data));
                data.SetImage(new Bitmap(image));
            }
            else return;
            // Another app may have the clipboard open for a moment; retry for up to half a second.
            Clipboard.SetDataObject(data, true, 10, 50);
            _lastWritten = GetClipboardSequenceNumber();
        }
        catch (Exception e) when (e is ExternalException or ArgumentException) { }
    }

    /// Puts received files on the clipboard (Ctrl+V in File Explorer copies them), unless something
    /// else was copied on this PC since `since`. A single picture also goes on as an image.
    public void WriteFiles(string[] paths, uint since)
    {
        var now = GetClipboardSequenceNumber();
        if (now != since && now != _lastWritten) return;
        try
        {
            var data = new DataObject();
            var list = new System.Collections.Specialized.StringCollection();
            list.AddRange(paths);
            data.SetFileDropList(list);
            data.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes(1)));  // copy, not move
            if (paths.Length == 1 && ImageExtensions.Contains(Path.GetExtension(paths[0]).ToLowerInvariant()) &&
                File.Exists(paths[0]) && new FileInfo(paths[0]).Length <= KeybridgeLink.Wire.MaxClipboard)
            {
                try
                {
                    using var image = Image.FromFile(paths[0]);
                    data.SetImage(new Bitmap(image));
                }
                catch (OutOfMemoryException) { }
            }
            Clipboard.SetDataObject(data, true, 10, 50);
            _lastWritten = GetClipboardSequenceNumber();
        }
        catch (Exception e) when (e is ExternalException or ArgumentException) { }
    }

    private static KeybridgeLink.Clipboard? Limit(byte kind, byte[] bytes) =>
        bytes.Length <= KeybridgeLink.Wire.MaxClipboard ? new KeybridgeLink.Clipboard(kind, bytes) : null;

    private static byte[] ToPng(Image image)
    {
        using var ms = new MemoryStream();
        image.Save(ms, ImageFormat.Png);
        return ms.ToArray();
    }
}
