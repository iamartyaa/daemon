#!/bin/zsh
# Builds Daemon.app: the menu bar app, the embedder process and llama.framework, signed.
# Usage: scripts/bundle.sh [debug|release]   (default release) -> build/Daemon.app
set -euo pipefail

config=${1:-release}
root=${0:A:h:h}
cd "$root"

# One build for all products: building them one by one prunes the other product's frameworks.
swift build -c "$config"
bin=$(swift build -c "$config" --show-bin-path)

app="$root/build/Daemon.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"

cp "$bin/Daemon" "$bin/DaemonEmbedder" "$app/Contents/MacOS/"
cp -R "$bin/llama.framework" "$bin/Sparkle.framework" "$app/Contents/Frameworks/"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/DaemonEmbedder"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Daemon"

# Ad-hoc unless DAEMON_SIGN_IDENTITY is set. Ad-hoc signatures change every build,
# so macOS asks for Accessibility again after each rebuild; a stable identity avoids that.
# Hardened runtime (needed for notarization) only with a real identity: ad-hoc pieces have no
# Team ID, so library validation would refuse to load llama.framework.
# Ad-hoc builds get an identifier-only designated requirement, so macOS keeps the Accessibility and
# Screen Recording grants across rebuilds (a plain ad-hoc signature changes with every build).
identity=${DAEMON_SIGN_IDENTITY:--}
runtime=(); [[ $identity != - ]] && runtime=(--options runtime)
requirement=(); [[ $identity == - ]] && requirement=(--requirements '=designated => identifier "app.mydaemon.Daemon"')
codesign --force --sign "$identity" "$app/Contents/Frameworks/llama.framework"
codesign --force --deep --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$identity" $runtime "$app/Contents/MacOS/DaemonEmbedder"
# The hardened runtime blocks Apple Events (browser/Finder reading) and the microphone without these.
entitlements=(); [[ $identity != - ]] && entitlements=(--entitlements "$root/scripts/Daemon.entitlements")
codesign --force --sign "$identity" $runtime $entitlements $requirement "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
