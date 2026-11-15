#!/bin/zsh
# Builds the Windows companion (Keybridge) on this Mac and puts Keybridge.exe in
# Keybridge/dist/, then rebuilds Keybridge so its setup page can serve the exe to the PC.
# Needs the .NET 8 SDK (~/.dotnet). The first build downloads the Windows runtime packs.
set -euo pipefail
cd "$(dirname "$0")"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[[ -x "$DOTNET" ]] || DOTNET="$(command -v dotnet)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

"$DOTNET" build Probe/Probe.csproj -c Release -v quiet
"$DOTNET" publish KeybridgePC/KeybridgePC.csproj -c Release -o out/KeybridgePC -v quiet
mkdir -p ../dist
rm -f ../dist/MXControlPC.exe ../dist/KeybridgePC.exe; cp out/KeybridgePC/Keybridge.exe ../dist/Keybridge.exe
ls -lh ../dist/Keybridge.exe
../build.sh
