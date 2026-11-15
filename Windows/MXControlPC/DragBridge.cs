using MXLink;

namespace MXControlPC;

/// The Windows half of dragging files across. All on the UI thread.
///
/// Mac → PC: a see-through window goes under the pointer, the left button is pressed onto it,
/// and it starts a real Windows drag of the files (which are still arriving; the drop waits).
/// PC → Mac: when the pointer reaches the left edge with the button held, a thin see-through
/// strip there catches the drag. If it's files, they go to the Mac and the Mac takes over the drag.
sealed class DragBridge(Injector injector)
{
    /// Starts sending dragged files to the Mac; returns the transfer id (null if it couldn't).
    public Func<string[], uint?>? SendDrag;
    public Action<string>? Log;

    private EdgeCatcher? _catcher;
    private System.Windows.Forms.Timer? _edgeTimer;
    private float _edgeY;
    private uint? _toMac;
    private DragHost? _host;

    // ---- Mac → PC

    public void StartFromMac(IncomingTransfer transfer)
    {
        _host?.Close();
        var host = new DragHost(transfer.TopLevel);
        _host = host;
        var p = Cursor.Position;
        host.Bounds = new Rectangle(p.X - 40, p.Y - 40, 80, 80);
        var started = false;
        host.Shown += (_, _) => host.BeginInvoke(() => injector.BeginDragFromMac(transfer.Done));
        host.MouseDown += (_, e) =>
        {
            if (started || e.Button != MouseButtons.Left) return;
            started = true;
            var data = new DataObject();
            var list = new System.Collections.Specialized.StringCollection();
            list.AddRange(transfer.TopLevel);
            data.SetFileDropList(list);
            data.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes(1)));
            Log?.Invoke($"drag from Mac: {transfer.TopLevel.Length} item(s)");
            var effect = host.DoDragDrop(data, DragDropEffects.Copy);   // returns once dropped or cancelled
            Log?.Invoke($"drag from Mac: {(effect == DragDropEffects.None ? "cancelled" : "dropped")}");
            injector.EndDragFromMac();
            host.Close();
            if (_host == host) _host = null;
        };
        // The press never arrived: give up.
        var giveUp = new System.Windows.Forms.Timer { Interval = 2000 };
        giveUp.Tick += (_, _) =>
        {
            giveUp.Dispose();
            if (started) return;
            injector.EndDragFromMac();
            host.Close();
        };
        giveUp.Start();
        host.Show();
    }

    // ---- PC → Mac

    /// The pointer hit the left edge with the left button down: is a file drag going on?
    public void CheckEdge(float fy)
    {
        _edgeY = fy;
        _catcher ??= new EdgeCatcher();
        _catcher.Files = null;
        _catcher.FilesEntered = () => ResolveEdge();
        var screen = SystemInformation.VirtualScreen;
        _catcher.Bounds = new Rectangle(screen.X, screen.Y, 6, screen.Height);
        _catcher.Show();
        _catcher.BringToFront();
        injector.Nudge();
        _edgeTimer?.Dispose();
        _edgeTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _edgeTimer.Tick += (_, _) => ResolveEdge();
        _edgeTimer.Start();
        // A second nudge in case the first came before the strip was on screen.
        var again = new System.Windows.Forms.Timer { Interval = 60 };
        again.Tick += (_, _) => { again.Dispose(); if (_edgeTimer is not null) injector.Nudge(); };
        again.Start();
    }

    private void ResolveEdge()
    {
        if (_edgeTimer is null) return;
        _edgeTimer.Dispose(); _edgeTimer = null;
        if (_catcher?.Files is { Length: > 0 } files && SendDrag?.Invoke(files) is uint id)
        {
            _toMac = id;
            Log?.Invoke($"drag to Mac: {files.Length} item(s)");
            injector.EdgeDragResolved(true, _edgeY);
        }
        else
        {
            _catcher?.Hide();
            injector.EdgeDragResolved(false, _edgeY);
        }
    }

    /// The Mac finished the drag that left this screen.
    public void MacDragEnded(uint id, bool dropped)
    {
        if (_toMac != id) return;
        _toMac = null;
        Log?.Invoke($"drag to Mac: {(dropped ? "dropped" : "cancelled")}");
        injector.ReleaseDragForMac();
        var hide = new System.Windows.Forms.Timer { Interval = 300 };
        hide.Tick += (_, _) => { hide.Dispose(); if (_toMac is null) _catcher?.Hide(); };
        hide.Start();
    }

    /// The link went away.
    public void Reset()
    {
        _edgeTimer?.Dispose(); _edgeTimer = null;
        _toMac = null;
        _catcher?.Hide();
    }
}

/// A see-through, never-activated window.
class GhostForm : Form
{
    public GhostForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        Opacity = 0.01;   // fully transparent windows don't take the mouse
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOPMOST = 0x8;
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
            return cp;
        }
    }
}

/// Mac → PC: sits under the pointer to take the button press that starts the Windows drag.
sealed class DragHost(string[] files) : GhostForm
{
    public string[] Files { get; } = files;
}

/// PC → Mac: a strip along the left edge that a Windows drag passes over on its way out.
sealed class EdgeCatcher : GhostForm
{
    public string[]? Files;
    public Action? FilesEntered;

    public EdgeCatcher()
    {
        AllowDrop = true;
        DragEnter += (_, e) =>
        {
            if (e.Data?.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files)
            {
                Files = files;
                e.Effect = DragDropEffects.Copy;
                FilesEntered?.Invoke();
            }
            else e.Effect = DragDropEffects.None;
        };
        DragOver += (_, e) => e.Effect = Files is null ? DragDropEffects.None : DragDropEffects.Copy;
        DragDrop += (_, _) => { };   // the Mac does the real drop
    }
}
