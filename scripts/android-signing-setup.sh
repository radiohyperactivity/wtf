#!/usr/bin/env bash
# Makes the Android app's release signing key, once, in local/android/ (not
# in git): wtf-release.jks, and key.properties, which Gradle reads
# (app/android/app/build.gradle.kts) and which has the key's random
# password. Nothing prints the password.
#
# Back the folder up: an app signed with this key can only be updated by
# an app signed with the same key, on devices and on Google Play.
#
# Needs keytool, from a JDK; KEYTOOL names it when it isn't on the PATH,
# and Android Studio's own JDK is tried too.
set -euo pipefail
cd "$(dirname "$0")/.."

dir=local/android
if [ -f "$dir/key.properties" ]; then
    echo "$dir/key.properties is there already; nothing to do." >&2
    exit 1
fi

keytool=${KEYTOOL:-}
for k in keytool "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
    /opt/android-studio/jbr/bin/keytool; do
    [ -n "$keytool" ] && break
    if command -v "$k" > /dev/null 2>&1; then keytool=$k; fi
done
if [ -z "$keytool" ]; then
    echo "No keytool: install a JDK, or name it with KEYTOOL." >&2
    exit 1
fi

mkdir -p "$dir"
chmod 700 "$dir"
# Letters and digits only, so that it needs no quoting in key.properties.
WTF_KEY_PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40)
export WTF_KEY_PASSWORD
"$keytool" -genkeypair -keystore "$dir/wtf-release.jks" -storetype PKCS12 \
    -alias wtf -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=WtF" \
    -storepass:env WTF_KEY_PASSWORD -keypass:env WTF_KEY_PASSWORD
(
    umask 077
    {
        echo "# The Android app's release signing key (scripts/android-signing-setup.sh)."
        echo "storeFile=wtf-release.jks"
        echo "keyAlias=wtf"
        echo "storePassword=$WTF_KEY_PASSWORD"
        echo "keyPassword=$WTF_KEY_PASSWORD"
    } > "$dir/key.properties"
)
echo "Made $dir/wtf-release.jks and $dir/key.properties; back them up."
