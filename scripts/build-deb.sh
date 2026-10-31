#!/usr/bin/env bash
# Builds the Linux app and packs it as dist/wtf-app_<version>_<arch>.deb, for
# Debian, Ubuntu and their relatives. Run it on such a machine, with Flutter
# and libsecret-1-dev installed.
#
# The app goes in /opt/wtf, as Flutter's bundle wants its lib/ and data/
# beside it; nothing goes in /usr/bin, where wtf is the command-line tool.
# The launcher entry and the icon are named after the app ID, io.bbj.wtf,
# which is how the desktop matches the running window to them.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd app && flutter build linux --release)

version=$(sed -n 's/^version: *//p' app/pubspec.yaml)
description=$(sed -n 's/^description: *"\(.*\)"$/\1/p' app/pubspec.yaml)
arch=$(dpkg --print-architecture)
deb=dist/wtf-app_${version}_$arch.deb

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/opt" "$root/usr/share/applications" "$root/usr/share/icons/hicolor/scalable/apps"
cp -r app/build/linux/x64/release/bundle "$root/opt/wtf"
cp app/linux/packaging/io.bbj.wtf.desktop "$root/usr/share/applications/"
cp logo/icon.svg "$root/usr/share/icons/hicolor/scalable/apps/io.bbj.wtf.svg"
chmod -R u=rwX,go=rX "$root"

# The system libraries the app needs (GTK, libsecret and so on), as Debian
# names them; the libraries in the bundle's lib/ come with it.
depends=$(
    mkdir -p "$root/debian"
    echo "Source: wtf-app" > "$root/debian/control"
    cd "$root"
    dpkg-shlibdeps -O -lopt/wtf/lib opt/wtf/wtf opt/wtf/lib/*.so 2>/dev/null |
        sed -n 's/^shlibs:Depends=//p'
)
rm -r "$root/debian"

mkdir "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<CONTROL
Package: wtf-app
Version: $version
Architecture: $arch
Maintainer: Bård Bjerke Johannessen <bbj@bbj.io>
Installed-Size: $(du -sk --exclude=DEBIAN "$root" | cut -f1)
Depends: $depends
Section: misc
Priority: optional
Description: WtF, Where to Find
 $description
CONTROL

mkdir -p dist
dpkg-deb --root-owner-group --build "$root" "$deb"
echo "built $deb"
