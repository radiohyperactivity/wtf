#!/usr/bin/env bash
# Builds the iOS app for real iPhones and iPads, signed for development, and
# installs it on the device given, if any; starting it is left to whoever
# holds the device:
#
#   scripts/ios-device.sh                 # only build
#   scripts/ios-device.sh <device>        # build and install
#
# The device is its identifier or name from "xcrun devicectl list devices".
# It works over SSH once scripts/ios-signing-setup.sh has been run on the Mac.
# A release build, since a debug build on a device only starts from the
# debugger. FLUTTER names Flutter when "flutter" isn't on the PATH.
set -euo pipefail
cd "$(dirname "$0")/../app"

keychain=~/Library/Keychains/wtf-signing.keychain-db
password_file=~/.config/wtf/signing-keychain-password
if [ ! -f "$keychain" ] || [ ! -f "$password_file" ]; then
    echo "No signing keychain: run scripts/ios-signing-setup.sh in Terminal on this Mac first." >&2
    exit 1
fi
security unlock-keychain -p "$(cat "$password_file")" "$keychain"

"${FLUTTER:-flutter}" build ios --release

if [ $# -gt 0 ]; then
    xcrun devicectl device install app --device "$1" build/ios/iphoneos/Runner.app
fi
