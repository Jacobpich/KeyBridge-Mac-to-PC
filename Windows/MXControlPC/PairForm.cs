namespace MXControlPC;

/// "Pair with the Mac?" with the 6-digit code to compare against the Mac.
sealed class PairForm : Form
{
    public event Action? Confirmed;
    public event Action? Cancelled;
    private readonly Label _hint;
    private readonly System.Windows.Forms.Button _pair, _cancel;
    private bool _done;

    public PairForm(string mac, string code)
    {
        Text = "MX Control for PC";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(380, 230);
        Font = new Font("Segoe UI", 10);

        var title = new Label { Text = $"Pair with {mac}?", Font = new Font("Segoe UI Semibold", 13), AutoSize = false,
                                TextAlign = ContentAlignment.MiddleCenter, Left = 0, Top = 16, Width = 380, Height = 30 };
        _hint = new Label { Text = "Check that the Mac shows the same code:", AutoSize = false, ForeColor = Color.DimGray,
                            TextAlign = ContentAlignment.MiddleCenter, Left = 0, Top = 50, Width = 380, Height = 24 };
        var codeLabel = new Label { Text = code, Font = new Font("Consolas", 30, FontStyle.Bold), AutoSize = false,
                                    TextAlign = ContentAlignment.MiddleCenter, Left = 0, Top = 80, Width = 380, Height = 60 };
        _cancel = new System.Windows.Forms.Button { Text = "Cancel", Left = 100, Top = 170, Width = 85, Height = 32 };
        _pair = new System.Windows.Forms.Button { Text = "Pair", Left = 195, Top = 170, Width = 85, Height = 32 };
        _pair.Click += (_, _) => { Confirmed?.Invoke(); ShowWaiting(); };
        _cancel.Click += (_, _) => { _done = true; Cancelled?.Invoke(); Close(); };
        Controls.AddRange([title, _hint, codeLabel, _cancel, _pair]);
        AcceptButton = _pair; CancelButton = _cancel;
        FormClosed += (_, _) => { if (!_done) { _done = true; Cancelled?.Invoke(); } };
    }

    /// This side confirmed; the Mac's user still has to click Pair.
    public void ShowWaiting()
    {
        _pair.Enabled = false;
        _hint.Text = "Now click Pair on the Mac.";
    }

    public new void Close()
    {
        _done = true;
        base.Close();
    }
}
