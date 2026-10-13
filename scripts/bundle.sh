#!/bin/zsh
# Builds Daemon.app: the menu bar app, the embedder process and llama.framework, signed.
# Usage: scripts/bundle.sh [debug|release]   (default release) -> build/Daemon.app
set -euo pipefail

config=${1:-release}
root=${0:A:h:h}
cd "$root"

swift build -c "$config" --product Daemon
swift build -c "$config" --product DaemonEmbedder
bin=$(swift build -c "$config" --show-bin-path)

app="$root/build/Daemon.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"

cp "$bin/Daemon" "$bin/DaemonEmbedder" "$app/Contents/MacOS/"
cp -R "$bin/llama.framework" "$app/Contents/Frameworks/"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/DaemonEmbedder"

# Ad-hoc unless DAEMON_SIGN_IDENTITY is set. Ad-hoc signatures change every build,
# so macOS asks for Accessibility again after each rebuild; a stable identity avoids that.
identity=${DAEMON_SIGN_IDENTITY:--}
codesign --force --sign "$identity" "$app/Contents/Frameworks/llama.framework"
codesign --force --sign "$identity" --options runtime "$app/Contents/MacOS/DaemonEmbedder"
codesign --force --sign "$identity" --options runtime "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
