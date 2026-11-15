using KeybridgeLink;

namespace KeybridgePC;

/// KeyBridge Control PC: a tray icon that keeps a Crossover connection to Keybridge on the Mac
/// and turns what it receives into input on this PC.
sealed class TrayApp : ApplicationContext
{
    private readonly Settings _settings = new();
    private readonly NotifyIcon _tray;
    private readonly ToolStripMenuItem _statusItem = new("Starting…") { Enabled = false };
    private readonly ToolStripMenuItem _startWithWindows = new("Start with Windows");
    private readonly Control _ui = new();          // for running work on the UI thread
    private readonly ClipboardSync _clipboard = new();
    private readonly Injector _injector = new();
    private readonly FileTransfers _transfers = new();
    private readonly DragBridge _drag;
    private IncomingTransfer? _dragFromMac;   // files the Mac is dragging over (offered just before the pointer)
    /// Copied files bigger than this stay put (dragged files have no limit).
    private const ulong ClipboardFileLimit = 2UL << 30;
    private readonly CancellationTokenSource _quit = new();
    private Session? _session;
    private PairForm? _pairForm;

    public TrayApp()
    {
        _ui.CreateControl();
        _startWithWindows.Checked = Settings.StartWithWindows;
        _startWithWindows.Click += (_, _) =>
        {
            Settings.StartWithWindows = !Settings.StartWithWindows;
            _startWithWindows.Checked = Settings.StartWithWindows;
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Connect to a Mac by address…", null, (_, _) => AskForAddress());
        menu.Items.Add("Forget paired Macs", null, (_, _) => { _settings.ForgetMacs(); _session?.Close("forgotten"); });
        menu.Items.Add(_startWithWindows);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Quit());
        _tray = new NotifyIcon { Icon = TrayIcon.Make(false), Text = "KeyBridge Control PC", ContextMenuStrip = menu, Visible = true };

        // First run: start with Windows by default.
        if (_settings.PairedMacName is null && !Settings.StartWithWindows)
        {
            try { Settings.StartWithWindows = true; _startWithWindows.Checked = true; } catch { }
        }

        // Hand control back straight from the network thread; the clipboard (which has to be
        // read on the UI thread and can be slow) follows right after.
        _transfers.Send = m =>
        {
            var s = _session;
            // An older Mac app would drop the link on a file message.
            if (s is null || s.State != SessionState.Trusted || !s.PeerSupports(Wire.FeatureFiles)) return false;
            s.Send(m);
            return true;
        };
        _transfers.Offered += OnOffered;
        _transfers.Log = AppLog.Write;
        _drag = new DragBridge(_injector) { SendDrag = files => _transfers.SendFiles(files, TransferPurpose.Drag), Log = AppLog.Write };
        _injector.OnEdgeWithButton = fy => _ui.BeginInvoke(() => _drag.CheckEdge(fy));
        _injector.OnReturn = fy =>
        {
            _session?.Send(new Returned(fy));
            _ui.BeginInvoke(AfterReturn);
        };
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) =>
        {
            var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
            _session?.Send(new KeybridgeLink.Screen((ushort)b.Width, (ushort)b.Height));
        };
        _ = Task.Run(ConnectLoop);
    }

    private void SetStatus(string text, bool linked)
    {
        if (_ui.InvokeRequired) { _ui.BeginInvoke(() => SetStatus(text, linked)); return; }
        if (_statusItem.Text != text) AppLog.Write(text);
        _statusItem.Text = text;
        var tip = "KeyBridge Control PC: " + text;
        _tray.Text = tip[..Math.Min(63, tip.Length)];
        _tray.Icon = TrayIcon.Make(linked);
    }

    /// Finds the Mac and stays connected; reconnects whenever the connection drops.
    private async Task ConnectLoop()
    {
        while (!_quit.IsCancellationRequested)
        {
            SetStatus("Looking for the Mac…", false);
            string? host = null; var port = _settings.MacPort;
            var found = await Discovery.FindMacAsync(TimeSpan.FromSeconds(2), _quit.Token);
            if (found is not null) { host = found.Host; port = found.Port; _settings.MacHost = host; _settings.MacPort = port; }
            else host = _settings.MacHost;
            if (host is null) { await Delay(3000); continue; }

            var b = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
            using var session = new Session(_settings.Identity, _settings) { ScreenWidth = (ushort)b.Width, ScreenHeight = (ushort)b.Height };
            session.StateChanged += s => OnState(session, s);
            session.MessageReceived += m => OnMessage(session, m);
            _session = session;
            SetStatus($"Connecting to {found?.Name ?? host}…", false);
            await session.RunAsync(host, port);
            _session = null;
            _injector.Deactivate();
            _injector.SetEdge(Layout.Left);   // until the next Mac says otherwise
            _transfers.Reset();
            _dragFromMac = null;
            _ui.BeginInvoke(_drag.Reset);
            if (_quit.IsCancellationRequested) return;
            SetStatus($"Disconnected ({session.CloseReason}). Retrying…", false);
            await Delay(2000);
        }
    }

    private async Task Delay(int ms)
    {
        try { await Task.Delay(ms, _quit.Token); } catch (OperationCanceledException) { }
    }

    private void OnState(Session session, SessionState state)
    {
        _ui.BeginInvoke(() =>
        {
            switch (state)
            {
                case SessionState.Pairing:
                    SetStatus($"Pair with {session.PeerName}?", false);
                    _pairForm?.Close();
                    _pairForm = new PairForm(session.PeerName, session.PairingCode ?? "------");
                    _pairForm.Confirmed += () => session.ConfirmPairing();
                    _pairForm.Cancelled += () => session.Close("pairing cancelled");
                    _pairForm.Show();
                    _pairForm.Activate();
                    break;
                case SessionState.WaitingForPeer:
                    _pairForm?.ShowWaiting();
                    SetStatus($"Confirm the code on {session.PeerName}", false);
                    break;
                case SessionState.Trusted:
                    _pairForm?.Close(); _pairForm = null;
                    SetStatus($"Linked to {session.PeerName}", true);
                    break;
                case SessionState.Closed:
                    _pairForm?.Close(); _pairForm = null;
                    break;
            }
        });
    }

    /// Runs on the network thread so input is injected with no extra hop.
    private void OnMessage(Session session, Msg m)
    {
        switch (m)
        {
            case KeybridgeLink.Clipboard clip:
                _ui.BeginInvoke(() => _clipboard.Write(clip));
                break;
            case FilesOffer or FileData or FilesDone or FilesCancel:
                _transfers.Received(m);
                break;
            case Layout layout:
                _injector.SetEdge(layout.Edge);
                AppLog.Write($"the Mac is through the {(layout.Edge switch { Layout.Right => "right", Layout.Top => "top", Layout.Bottom => "bottom", _ => "left" })} edge");
                break;
            case DragEnded ended:
                _ui.BeginInvoke(() => _drag.MacDragEnded(ended.Id, ended.Dropped));
                break;
            case KeybridgeLink.Enter:
                _injector.Handle(m);
                if (Interlocked.Exchange(ref _dragFromMac, null) is { } drag) _ui.BeginInvoke(() => _drag.StartFromMac(drag));
                _ui.BeginInvoke(() => SetStatus($"Controlled from {session.PeerName}", true));
                break;
            case KeybridgeLink.Leave:
                _injector.Handle(m);
                _ui.BeginInvoke(() => SetStatus($"Linked to {session.PeerName}", true));
                break;
            default:
                _injector.Handle(m);
                break;
        }
    }

    /// Control went back to the Mac: send the clipboard if it changed.
    private void AfterReturn()
    {
        var session = _session;
        if (session is null) return;
        switch (_clipboard.PayloadIfChanged())
        {
            case { Data: { } clip }: session.Send(clip); break;
            case { Files: { } files }: _transfers.SendFiles(files, TransferPurpose.Clipboard, ClipboardFileLimit); break;
        }
        SetStatus($"Linked to {session.PeerName}", true);
    }

    /// Files are on their way from the Mac (network thread).
    private void OnOffered(IncomingTransfer t)
    {
        if (t.Purpose == TransferPurpose.Clipboard)
        {
            var since = ClipboardSync.SequenceNumber;
            t.Done.ContinueWith(done =>
            {
                if (done.Result) _ui.BeginInvoke(() => _clipboard.WriteFiles(t.TopLevel, since));
            });
        }
        else if (t.Purpose == TransferPurpose.Drag)
        {
            _dragFromMac = t;
        }
    }

    private void AskForAddress()
    {
        var address = Prompt.Show("Connect to a Mac", "The Mac's name or IP address (for example your-mac.local or the address shown in the Mac’s network settings):",
                                  _settings.MacHost ?? "");
        if (string.IsNullOrWhiteSpace(address)) return;
        _settings.MacHost = address.Trim();
        _session?.Close("new address");
    }

    private void Quit()
    {
        _quit.Cancel();
        _session?.Close("quit");
        _injector.Deactivate();
        _tray.Visible = false;
        ExitThread();
    }
}

/// The tray icon: two little screens, blue while linked.
static class TrayIcon
{
    public static Icon Make(bool linked)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var color = linked ? Color.FromArgb(10, 100, 216) : Color.FromArgb(120, 120, 120);
            using var pen = new Pen(color, 3);
            g.DrawRectangle(pen, 2, 4, 16, 12);
            g.DrawRectangle(pen, 12, 14, 17, 13);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}

static class Prompt
{
    public static string? Show(string title, string text, string initial)
    {
        using var form = new Form { Text = title, Width = 460, Height = 170, FormBorderStyle = FormBorderStyle.FixedDialog,
                                    StartPosition = FormStartPosition.CenterScreen, MinimizeBox = false, MaximizeBox = false };
        var label = new Label { Left = 12, Top = 12, Width = 420, Height = 36, Text = text };
        var box = new TextBox { Left = 12, Top = 52, Width = 420, Text = initial };
        var ok = new System.Windows.Forms.Button { Text = "Connect", Left = 266, Top = 86, Width = 80, DialogResult = DialogResult.OK };
        var cancel = new System.Windows.Forms.Button { Text = "Cancel", Left = 352, Top = 86, Width = 80, DialogResult = DialogResult.Cancel };
        form.Controls.AddRange([label, box, ok, cancel]);
        form.AcceptButton = ok; form.CancelButton = cancel;
        return form.ShowDialog() == DialogResult.OK ? box.Text : null;
    }
}
