#!/bin/zsh
# Builds the Windows companion (MX Control for PC) on this Mac and puts MXControlPC.exe in
# MX Control/dist/, then rebuilds MX Control so its setup page can serve the exe to the PC.
# Needs the .NET 8 SDK (~/.dotnet). The first build downloads the Windows runtime packs.
set -euo pipefail
cd "$(dirname "$0")"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[[ -x "$DOTNET" ]] || DOTNET="$(command -v dotnet)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

"$DOTNET" build Probe/Probe.csproj -c Release -v quiet
"$DOTNET" publish MXControlPC/MXControlPC.csproj -c Release -o out/MXControlPC -v quiet
mkdir -p ../dist
cp out/MXControlPC/MXControlPC.exe ../dist/MXControlPC.exe
ls -lh ../dist/MXControlPC.exe
../build.sh
