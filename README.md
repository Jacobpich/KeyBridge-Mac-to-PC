# KeyBridge Mac to PC

Use a keyboard, mouse, or trackpad connected to a Mac to control a Windows PC on the same local network. Move the pointer across to the PC to switch control. The apps pair with a six-digit confirmation code and can share clipboard content and transfer files.

## Download both apps

Open the [latest GitHub release](https://github.com/Jacobpich/KeyBridge-Mac-to-PC/releases/latest) and download both files from the same release:

| Computer | File | Requirements |
| --- | --- | --- |
| Mac | `MX-Control-macOS-arm64.zip` | Apple silicon, macOS 15 or later |
| PC | `MXControlPC.exe` | 64-bit Windows on x86-64. The .NET runtime is included. |

The v1.0.0 downloads and app menus still use the original **MX Control** name. On the Mac, unzip the download, move **MX Control.app** to Applications, and open it. On the PC, save **MXControlPC.exe** somewhere permanent and run it. The Windows app appears in the system tray. Its **Start with Windows** tray option controls whether it launches at sign-in.

The hobby builds are not notarized on macOS or Authenticode signed on Windows. If your system blocks a prebuilt app, use the local build instructions below or ask your administrator for an approved build. Releases include SHA-256 checksums for the two files.

## Pair and arrange your screens

1. Connect both computers to the same local network. Keep the keyboard and mouse connected to the Mac.
2. The PC's screen also needs to appear as an extended display on the Mac. For a monitor shared by both computers, connect each computer to a separate input on that monitor and switch it to the PC input. Make sure macOS still sees that display while the PC input is selected. In **System Settings → Displays → Arrange**, put that display directly to the right of the Mac's display.
3. In **System Settings → Privacy & Security**, grant **Accessibility** to **MX Control** and allow **Local Network** access if macOS asks. The separate Logitech device controls may also ask for **Input Monitoring**.
4. Open **MX Control → Crossover → Settings**. Under **PC’s screen**, choose the display showing Windows and turn on Crossover. If the PC does not automatically find the Mac, right-click the Windows tray icon, select **Connect to a Mac by address**, and enter your Mac’s local IP address.
5. Compare the six-digit code on both computers and confirm on each. Move the pointer to the right from the Mac display to enter Windows. Move it off the left edge of Windows to return, or press **Control–Option–Command–Escape** on the Mac keyboard.

Crossover uses TCP port **47820** on the Mac for the session and UDP port **47821** for local discovery. Use the same private network, and check that a guest network or firewall isn't isolating the computers. The Windows tray menu and the Mac's Crossover settings also let you forget a pairing and start over.

For clipboard sharing, turn on **Share the clipboard** under Crossover settings. Copy text, an image, or files, cross to the other computer, then paste there. You can also drag files between Finder and File Explorer. If a transfer does not work, first confirm both machines are running the same release.

## Build from source

Download the repository or clone it. The Mac app uses Swift Package Manager with no external Swift packages. The PC app targets .NET 8 and includes its companion protocol project.

- **Mac:** Install Xcode or Command Line Tools with Swift 6 or newer. From the repository root, run `./build.sh` and open `dist/MX Control.app`. The build signs locally without a developer certificate by default. You can provide your own certificate via `SIGN_IDENTITY`.
- **Windows:** Install the [.NET 8 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/8.0). In PowerShell at the repository root, run the command below. The self-contained executable will be in `Windows\out\MXControlPC`.
- **Both from a Mac:** Install the .NET 8 SDK and run `./Windows/build-windows.sh`. It places the Windows executable beside the Mac app in `dist` and also embeds it in the app for the optional local setup page.

```powershell
dotnet publish Windows/MXControlPC/MXControlPC.csproj -c Release -o Windows/out/MXControlPC
```
