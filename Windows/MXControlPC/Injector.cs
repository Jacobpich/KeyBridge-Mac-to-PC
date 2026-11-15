using System.Runtime.InteropServices;
using MXLink;

namespace MXControlPC;

/// Turns Crossover messages into real Windows input with SendInput.
/// Mostly runs on the network thread; the drag hooks come from the UI thread, so it's all locked.
sealed class Injector
{
    /// The pointer was pushed past the PC screen's left edge, at this fraction of its height.
    public Action<float>? OnReturn;
    /// The pointer reached the left edge with the left button held (maybe dragging files).
    /// The handler must call EdgeDragResolved.
    public Action<float>? OnEdgeWithButton;
    public bool Active { get; private set; }

    private readonly object _gate = new();
    private Task<bool>? _dropReady;     // a drag from the Mac: its files are still arriving
    private bool _dropHeld;             // ...and the button came up before they had
    private bool _edgeCheck;            // waiting to hear whether a drag at the edge is files
    private bool _holdingForMac;        // the left button stays down while the Mac carries the drag

    private double _x, _y;              // pointer position with sub-pixel remainder
    private double _wheel, _hwheel;     // wheel remainder, in 1/120 notch units
    private long _enteredAt;            // Environment.TickCount64 when control arrived
    private bool _armed;                // may the left edge send control back yet?

    /// Right after control arrives at the left edge, a small wobble to the left shouldn't send it
    /// straight back. The edge works again once the pointer has moved this far in, or after this long.
    private const double ArmDistance = 6;
    private const long ArmAfterMs = 150;
    private readonly HashSet<(ushort, bool)> _keys = [];
    private readonly HashSet<byte> _buttons = [];

    public void Handle(Msg m)
    {
        lock (_gate) HandleLocked(m);
    }

    private void HandleLocked(Msg m)
    {
        switch (m)
        {
            case MXLink.Enter e: Enter(e.X, e.Y); break;
            case MXLink.Move mv: Move(mv.Dx, mv.Dy); break;
            case MXLink.Button b: Button(b.Which, b.Down); break;
            case MXLink.Scroll s: Scroll(s.Vertical, s.Horizontal); break;
            case MXLink.Key k: Key(k.Scan, k.Extended, k.Down); break;
            case MXLink.VKey v: VirtualKey(v.Vk, v.Down); break;
            case MXLink.Leave: DeactivateLocked(); break;
        }
    }

    /// Lets go of every key and button this app is holding (control left, or the Mac went away).
    public void Deactivate()
    {
        lock (_gate) DeactivateLocked();
    }

    private void DeactivateLocked()
    {
        Active = false;
        _edgeCheck = false; _holdingForMac = false; _dropReady = null; _dropHeld = false;
        foreach (var (scan, ext) in _keys.ToArray()) Key(scan, ext, false);
        foreach (var b in _buttons.ToArray()) Button(b, false);
        _wheel = _hwheel = 0;
    }

    private static (int X, int Y, int W, int H) Desktop() =>
        (Native.GetSystemMetrics(Native.SM_XVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_YVIRTUALSCREEN),
         Native.GetSystemMetrics(Native.SM_CXVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_CYVIRTUALSCREEN));

    private void Enter(float fx, float fy)
    {
        var d = Desktop();
        _x = d.X + fx * (d.W - 1);
        _y = d.Y + fy * (d.H - 1);
        _enteredAt = Environment.TickCount64;
        _armed = _x - d.X >= ArmDistance;
        Active = true;
        MoveTo();
    }

    private void Move(float dx, float dy)
    {
        if (!Active) return;
        var d = Desktop();
        // Start from where the pointer really is, in case something else moved it.
        if (Native.GetCursorPos(out var p) && (Math.Abs(p.X - _x) >= 2 || Math.Abs(p.Y - _y) >= 2)) { _x = p.X; _y = p.Y; }
        _x += dx;
        _y = Math.Clamp(_y + dy, d.Y, d.Y + d.H - 1);
        if (!_armed && (_x - d.X >= ArmDistance || Environment.TickCount64 - _enteredAt >= ArmAfterMs)) _armed = true;
        // While a drag from the Mac is on this screen, or we're finding out what's being dragged,
        // the left edge is a wall.
        if (_x < d.X && (!_armed || _dropReady is not null || _edgeCheck)) _x = d.X;
        if (_x < d.X)
        {
            var fy = (float)((_y - d.Y) / Math.Max(1, d.H - 1));
            if (_buttons.Contains(0) && OnEdgeWithButton is { } edge)
            {
                _x = d.X;
                MoveTo();
                _edgeCheck = true;
                edge(fy);
                return;
            }
            DeactivateLocked();
            OnReturn?.Invoke(fy);
            return;
        }
        _x = Math.Min(_x, d.X + d.W - 1);
        MoveTo();
    }

    private void MoveTo()
    {
        var d = Desktop();
        var input = Native.Mouse(
            (int)Math.Round((_x - d.X) * 65535.0 / Math.Max(1, d.W - 1)),
            (int)Math.Round((_y - d.Y) * 65535.0 / Math.Max(1, d.H - 1)),
            0, Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK);
        Native.Send(input);
    }

    private void Button(byte which, bool down)
    {
        if (down && !Active) return;
        // A drag from the Mac: don't drop until its files are all here.
        if (which == 0 && !down && _dropReady is { IsCompleted: false } ready)
        {
            if (_dropHeld) return;
            _dropHeld = true;
            ready.ContinueWith(t => { lock (_gate) { if (_dropReady == ready) FinishDrop(t.Result); } });
            return;
        }
        if (which == 0 && !down && _dropReady is { } done) { FinishDrop(done.Result); return; }
        uint flags; uint data = 0;
        switch (which)
        {
            case 0: flags = down ? Native.MOUSEEVENTF_LEFTDOWN : Native.MOUSEEVENTF_LEFTUP; break;
            case 1: flags = down ? Native.MOUSEEVENTF_RIGHTDOWN : Native.MOUSEEVENTF_RIGHTUP; break;
            case 2: flags = down ? Native.MOUSEEVENTF_MIDDLEDOWN : Native.MOUSEEVENTF_MIDDLEUP; break;
            case 3: flags = down ? Native.MOUSEEVENTF_XDOWN : Native.MOUSEEVENTF_XUP; data = Native.XBUTTON1; break;
            case 4: flags = down ? Native.MOUSEEVENTF_XDOWN : Native.MOUSEEVENTF_XUP; data = Native.XBUTTON2; break;
            default: return;
        }
        if (down) _buttons.Add(which); else if (!_buttons.Remove(which)) return;
        Native.Send(Native.Mouse(0, 0, data, flags));
    }

    // ---- Drags

    /// A drag from the Mac arrived: press the left button (onto the drag window under the pointer)
    /// and hold the drop until `filesReady` completes. Called on the UI thread.
    public void BeginDragFromMac(Task<bool> filesReady)
    {
        lock (_gate)
        {
            if (!Active) return;
            _dropReady = filesReady; _dropHeld = false;
            _buttons.Add(0);
            Native.Send(Native.Mouse(0, 0, 0, Native.MOUSEEVENTF_LEFTDOWN));
        }
    }

    /// The Mac's drag is over on this side (DoDragDrop returned).
    public void EndDragFromMac()
    {
        lock (_gate) { _dropReady = null; _dropHeld = false; }
    }

    private void FinishDrop(bool filesArrived)
    {
        _dropReady = null; _dropHeld = false;
        // Files didn't make it: cancel the drag rather than drop empty files.
        if (!filesArrived) TapVirtualKey(Native.VK_ESCAPE);
        if (_buttons.Remove(0)) Native.Send(Native.Mouse(0, 0, 0, Native.MOUSEEVENTF_LEFTUP));
    }

    /// Nudges the pointer a pixel in and back, so Windows' drag loop notices the window under it.
    public void Nudge()
    {
        lock (_gate)
        {
            var x = _x; _x += 2; MoveTo(); _x = x; MoveTo();
        }
    }

    /// Answer to OnEdgeWithButton. Files: control goes to the Mac with the left button still held
    /// here until DragEnded. Not files: control goes back as usual (the button is let go).
    public void EdgeDragResolved(bool files, float fy)
    {
        lock (_gate)
        {
            if (!_edgeCheck) return;
            _edgeCheck = false;
            if (files)
            {
                Active = false;
                _holdingForMac = true;
                foreach (var (scan, ext) in _keys.ToArray()) Key(scan, ext, false);
                _wheel = _hwheel = 0;
            }
            else DeactivateLocked();
        }
        OnReturn?.Invoke(fy);
    }

    /// The Mac finished the drag that left this screen: cancel the Windows side and let go.
    public void ReleaseDragForMac()
    {
        lock (_gate)
        {
            if (!_holdingForMac) return;
            _holdingForMac = false;
            TapVirtualKey(Native.VK_ESCAPE);
            if (_buttons.Remove(0)) Native.Send(Native.Mouse(0, 0, 0, Native.MOUSEEVENTF_LEFTUP));
        }
    }

    private static void TapVirtualKey(ushort vk)
    {
        Native.Send(Native.Keyboard(vk, 0, 0));
        Native.Send(Native.Keyboard(vk, 0, Native.KEYEVENTF_KEYUP));
    }

    private void Scroll(float vertical, float horizontal)
    {
        if (!Active) return;
        _wheel += vertical * 120; _hwheel += horizontal * 120;
        var v = (int)_wheel; var h = (int)_hwheel;
        _wheel -= v; _hwheel -= h;
        if (v != 0) Native.Send(Native.Mouse(0, 0, unchecked((uint)v), Native.MOUSEEVENTF_WHEEL));
        if (h != 0) Native.Send(Native.Mouse(0, 0, unchecked((uint)h), Native.MOUSEEVENTF_HWHEEL));
    }

    private void Key(ushort scan, bool extended, bool down)
    {
        if (down && !Active) return;
        if (down) _keys.Add((scan, extended)); else if (!_keys.Remove((scan, extended))) return;
        uint flags = Native.KEYEVENTF_SCANCODE | (extended ? Native.KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : Native.KEYEVENTF_KEYUP);
        Native.Send(Native.Keyboard(0, scan, flags));
    }

    private void VirtualKey(ushort vk, bool down)
    {
        if (down && !Active) return;
        Native.Send(Native.Keyboard(vk, 0, Native.KEYEVENTF_EXTENDEDKEY | (down ? 0 : Native.KEYEVENTF_KEYUP)));
    }
}

static class Native
{
    public const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004,
        MOUSEEVENTF_RIGHTDOWN = 0x0008, MOUSEEVENTF_RIGHTUP = 0x0010, MOUSEEVENTF_MIDDLEDOWN = 0x0020,
        MOUSEEVENTF_MIDDLEUP = 0x0040, MOUSEEVENTF_XDOWN = 0x0080, MOUSEEVENTF_XUP = 0x0100,
        MOUSEEVENTF_WHEEL = 0x0800, MOUSEEVENTF_HWHEEL = 0x1000, MOUSEEVENTF_VIRTUALDESK = 0x4000,
        MOUSEEVENTF_ABSOLUTE = 0x8000;
    public const uint XBUTTON1 = 1, XBUTTON2 = 2;
    public const ushort VK_ESCAPE = 0x1B;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001, KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_SCANCODE = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion u; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetCursorPos(out POINT point);

    public static INPUT Mouse(int dx, int dy, uint data, uint flags) =>
        new() { type = INPUT_MOUSE, u = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags } } };

    public static INPUT Keyboard(ushort vk, ushort scan, uint flags) =>
        new() { type = INPUT_KEYBOARD, u = new InputUnion { ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } } };

    public static void Send(INPUT input) => SendInput(1, [input], Marshal.SizeOf<INPUT>());
}
