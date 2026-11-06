#!/usr/bin/env bash
# Builds the Android app, signed with the release key when there is one
# (scripts/android-signing-setup.sh), and installs it on the device given,
# if any; starting it is left to whoever holds the device:
#
#   scripts/android-device.sh                    # only build
#   scripts/android-device.sh <serial number>    # build and install
#
# The device is named by its serial number ("adb devices -l" shows it, or
# Settings, About phone), so that it is found however it is connected: by
# cable, or over Wi-Fi with wireless debugging, once paired with
# "adb pair". Over Wi-Fi, a device that adb hasn't connected to yet is
# looked for on the network. An update keeps the app's data.
#
# FLUTTER names Flutter and ADB adb when they aren't on the PATH; the
# Android SDK's adb is tried too.
set -euo pipefail
cd "$(dirname "$0")/../app"

adb=${ADB:-}
# On Windows (Git Bash), LOCALAPPDATA is a Windows path.
local_appdata=$(cygpath -u "${LOCALAPPDATA:-}" 2> /dev/null || echo "${LOCALAPPDATA:-}")
for a in adb "${ANDROID_HOME:-}/platform-tools/adb" \
    "$local_appdata/Android/Sdk/platform-tools/adb.exe" \
    "$HOME/Library/Android/sdk/platform-tools/adb" "$HOME/Android/Sdk/platform-tools/adb"; do
    [ -n "$adb" ] && break
    if command -v "$a" > /dev/null 2>&1; then adb=$a; fi
done

"${FLUTTER:-flutter}" build apk --release
[ $# -gt 0 ] || exit 0
want=$1
if [ -z "$adb" ]; then
    echo "No adb: install the Android SDK's platform tools, or name it with ADB." >&2
    exit 1
fi

# The adb name of the connected device with serial number $want, if any.
find_device() {
    # adb on Windows ends its lines with \r.
    "$adb" devices | tr -d '\r' | awk 'NR > 1 && $2 == "device" { print $1 }' | while read -r d; do
        # The device's own serial number: "adb get-serialno" gives adb's
        # name for it, which over Wi-Fi isn't. Its input not from the list
        # being read.
        if [ "$("$adb" -s "$d" shell getprop ro.serialno < /dev/null 2> /dev/null | tr -d '\r')" = "$want" ]; then
            echo "$d"
            break
        fi
    done
}

device=$(find_device)
if [ -z "$device" ]; then
    # Paired devices announce themselves as adb-<serial number>-<random>.
    address=$("$adb" mdns services | tr -d '\r' |
        awk -v s="adb-$want-" 'index($1, s) == 1 && $2 ~ /_adb-tls-connect/ { print $3; exit }')
    if [ -n "$address" ]; then
        "$adb" connect "$address" > /dev/null
        device=$(find_device)
    fi
fi
if [ -z "$device" ]; then
    echo "Device $want isn't connected: plug it in, or turn on wireless debugging" >&2
    echo "(Settings, Developer options) on the same network as this computer." >&2
    exit 1
fi

if ! out=$("$adb" -s "$device" install -r build/app/outputs/flutter-apk/app-release.apk 2>&1); then
    echo "$out" >&2
    if [[ $out == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
        echo "The app on the device is signed with another key. Uninstalling it (which loses" >&2
        echo "its login) lets this one in: $adb -s $device uninstall io.bbj.wtf" >&2
    fi
    exit 1
fi
echo "$out"
