# Keybridge

Use the keyboard, mouse or trackpad connected to a Mac to control a Windows PC on the same local network. It comes as two apps: **Keybridge** on the Mac and **KeyBridge Control PC** on Windows. Move the pointer onto the PC's screen to switch control, and move it back to return. The two apps pair with a six-digit code, encrypt everything they send, and can share the clipboard and drag files between Finder and File Explorer.

Any brand of keyboard, mouse or trackpad works. If you have a Logitech device (such as MX Keys or MX Master), Keybridge also shows its battery, backlight, button and Easy-Switch settings.

## Download both apps

Open the [latest release](https://github.com/Jacobpich/KeyBridge-Mac-to-PC/releases/latest) and download both files from the same release:

| Computer | File | Requirements |
| --- | --- | --- |
| Mac | `Keybridge-macOS-arm64.zip` | Apple silicon, macOS 15 or later |
| PC | `KeyBridge-Control-PC.exe` | 64-bit Windows 10 or 11 on x86-64. The .NET runtime is included. |

On the Mac, unzip the download, move **Keybridge.app** to Applications, and open it. It lives in the menu bar. On the PC, save **KeyBridge-Control-PC.exe** somewhere permanent and run it. **KeyBridge Control PC** lives in the system tray, and its **Start with Windows** option controls whether it opens when you sign in.

The builds aren't notarized on macOS or Authenticode-signed on Windows. On the Mac, if it won't open, right-click the app and choose **Open**. On Windows, if SmartScreen says it protected your PC, click **More info → Run anyway**, or right-click the file → **Properties** → tick **Unblock**. Each release includes SHA-256 checksums for both files.

### Updating from MX Control

Keybridge used to be called MX Control. Quit MX Control on the Mac, open Keybridge, and your settings and pairing move over. On the PC, just run the new **KeyBridge-Control-PC.exe**: it closes the old tray app (MX Control for PC, or Keybridge from 1.1.0), keeps the pairing, and takes over **Start with Windows**. You can then delete the old `MXControlPC.exe` or `Keybridge.exe`. A Mac and PC on different versions still work together, but copying and dragging files needs both on 1.1.0 or later.

## Set up

1. Connect both computers to the same local network. Keep the keyboard and mouse connected to the Mac.
2. On the Mac, in **System Settings → Privacy & Security → Accessibility**, turn on **Keybridge** (Keybridge asks the first time). Allow **Local Network** access if macOS asks.
3. Run Keybridge on the Mac and KeyBridge Control PC on the PC. The PC finds the Mac by itself. If it doesn't, right-click the tray icon, choose **Connect to a Mac by address**, and enter the Mac's local IP address.
4. Compare the six-digit code on both screens and confirm on each.
5. Arrange the screens: click Keybridge in the menu bar, open **Crossover → Arrange screens**, and drag the PC's screen to where it sits next to the Mac's: to the left or right of, above or below any Mac screen. The same editor is in **Crossover settings**.

Move the pointer off that side of the Mac's screen to control the PC, and back the way it came to return. **Control–Option–Command–Escape** on the Mac keyboard always brings control back to the Mac.

If one monitor is connected to both computers (on two inputs), choose it under **PC's monitor is also plugged into this Mac** in Crossover settings. Keybridge then follows that monitor's place in **System Settings → Displays → Arrange**, and dragging the PC in Keybridge moves it there too. It also keeps Mac windows off that monitor while the PC is linked.

Keybridge uses TCP port **47820** on the Mac for the connection and UDP port **47821** for finding it. Use the same private network, and check that a guest network or firewall isn't keeping the computers apart. The Windows tray menu and the Mac's Crossover settings can forget a pairing so you can start over.

## Clipboard and files

With **Share the clipboard** on (Crossover settings), copy text, an image, or files in Finder or File Explorer, move to the other computer, and paste. You can also drag files and folders across: from Finder onto the PC's screen and drop them in File Explorer, or from File Explorer back onto the Mac. Large files take a moment; the drop waits until they've arrived. Copied files are limited to 2 GB; dragged files have no limit.

## Troubleshooting

Both apps keep a log:

- Mac: `~/Library/Logs/Keybridge.log`
- PC: `%LOCALAPPDATA%\KeyBridge\log.txt`

## Build from source

The Mac app uses Swift Package Manager with no external packages. The PC app targets .NET 8.

- **Mac:** Install Xcode or the Command Line Tools with Swift 6 or newer. From the repository root, run `./build.sh` and open `dist/Keybridge.app`. It's signed ad hoc by default; to sign with your own certificate (so macOS keeps the Accessibility permission across rebuilds), put `SIGN_IDENTITY` and optionally `BUNDLE_ID` in a `local.env` file next to `build.sh` (git ignores it).
- **Windows:** Install the [.NET 8 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/8.0) and run, in PowerShell at the repository root:

  ```powershell
  dotnet publish Windows/KeybridgePC/KeybridgePC.csproj -c Release -o Windows/out/KeybridgePC
  ```

  The self-contained `KeyBridge-Control-PC.exe` is in `Windows\out\KeybridgePC`.
- **Both from a Mac:** Install the .NET 8 SDK and run `./Windows/build-windows.sh`. It puts `KeyBridge-Control-PC.exe` next to the Mac app in `dist` and builds it into the app, so the Mac can serve it to the PC from **Crossover settings → Share the PC installer on the network**.

Pushing a tag such as `v1.1.0` builds both apps on GitHub Actions and publishes them as a release.
