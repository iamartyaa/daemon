#!/bin/zsh
# Release disk image: build/Daemon.dmg from a release build of Daemon.app.
# Notarized only when both are set (needs the Apple Developer Program):
#   DAEMON_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
#   DAEMON_NOTARY_PROFILE=<profile saved with `xcrun notarytool store-credentials`>
set -euo pipefail
root=${0:A:h:h}
cd "$root"

scripts/bundle.sh release
dmg="$root/build/Daemon.dmg"
rm -f "$dmg"
staging=$(mktemp -d)
cp -R build/Daemon.app "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Daemon" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
rm -r "$staging"

if [[ -n ${DAEMON_SIGN_IDENTITY:-} && -n ${DAEMON_NOTARY_PROFILE:-} ]]; then
    codesign --force --sign "$DAEMON_SIGN_IDENTITY" "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$DAEMON_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
else
    echo "Not notarized: set DAEMON_SIGN_IDENTITY and DAEMON_NOTARY_PROFILE for a release build."
fi
echo "Built $dmg"
