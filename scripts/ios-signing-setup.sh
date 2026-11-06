#!/usr/bin/env bash
# Sets up a Mac so that the iOS app can be signed for real iPhones over SSH,
# by scripts/ios-device.sh, with nobody at the Mac.
#
# Over SSH, the login keychain stays locked, even when it is unlocked on the
# Mac's screen, so codesign can't use the signing key in it. This moves the
# Apple Development certificate and its key into a keychain of their own,
# wtf-signing, whose password is a random one kept in
# ~/.config/wtf/signing-keychain-password (readable only by you). It is not
# your Mac password, and opens only that keychain; ios-device.sh unlocks the
# keychain with it before each build.
#
# Run it once, in Terminal on the Mac itself (not over SSH), after Xcode has
# made the certificate (Signing & Capabilities, with your team chosen).
# Exporting the key from the login keychain asks for your Mac password. When
# Xcode makes a new certificate, about once a year, run it again.
set -euo pipefail

dir=~/.config/wtf
password_file=$dir/signing-keychain-password
keychain=~/Library/Keychains/wtf-signing.keychain-db
login=~/Library/Keychains/login.keychain-db

identity=$(security find-identity -v -p codesigning "$login" | awk '/"Apple Development/ { print $2; exit }')
if [ -z "$identity" ]; then
    echo "There is no Apple Development certificate in the login keychain. Let Xcode make one first," >&2
    echo "or, if it is already in the wtf-signing keychain, there is nothing to do." >&2
    exit 1
fi

mkdir -p "$dir"
chmod 700 "$dir"
if [ ! -f "$password_file" ]; then
    (umask 077 && openssl rand -base64 30 > "$password_file")
fi
if [ ! -f "$keychain" ]; then
    security create-keychain -p "$(cat "$password_file")" "$keychain"
fi
security unlock-keychain -p "$(cat "$password_file")" "$keychain"
# No settings means it doesn't lock by itself while the Mac is running.
security set-keychain-settings "$keychain"

# The export carries every identity in the login keychain, so it is imported
# whole; only the Apple Development one is removed from the login keychain
# below. The file and its password are thrown away at the end.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
p12_password=$(openssl rand -base64 30)
security export -k "$login" -t identities -f pkcs12 -P "$p12_password" -o "$work/identities.p12"
security import "$work/identities.p12" -k "$keychain" -P "$p12_password" -T /usr/bin/codesign -T /usr/bin/security
# Lets Apple's tools, codesign among them, use the keys without asking.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$password_file")" "$keychain" > /dev/null

if ! security find-identity -v -p codesigning "$keychain" | grep -q "$identity"; then
    echo "The certificate didn't arrive in the wtf-signing keychain; the login keychain is left as it was." >&2
    exit 1
fi
# The same certificate in two keychains makes codesign refuse it as
# ambiguous, so it stays only in the new one.
security delete-identity -Z "$identity" "$login"

# Xcode and codesign look in the keychains on this list.
others=$(security list-keychains -d user | tr -d '"' | grep -v 'wtf-signing.keychain-db' || true)
# shellcheck disable=SC2086
security list-keychains -d user -s "$keychain" $others

echo "Done: the Apple Development certificate is in the wtf-signing keychain."
