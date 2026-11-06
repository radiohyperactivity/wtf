#!/usr/bin/env bash
# Builds a release of the server and the command-line tool into
# dist/release/: for every system wtfd runs on, an archive with wtf and wtfd
# (the web app built into wtfd), LICENSE and a README (release-readme.txt),
# in one folder named as the archive:
#
#   wtf-<version>-windows-<arch>.zip
#   wtf-<version>-linux-<arch>.tar.gz
#   wtf-<version>-macos-<arch>.tar.gz
#
# The version is the app's, from app/pubspec.yaml. It runs wherever
# scripts/build.sh does (Linux, macOS, Git Bash on Windows), and needs zip,
# and Flutter for the web app: FLUTTER names it when "flutter" isn't on the
# PATH (FLUTTER=~/fvm/default/bin/flutter).
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml)
release=dist/release

# tarball packs $release/<name>/ as <name>.tar.gz, owned by root, with the
# programs executable. chmod does that on Linux and macOS; in Git Bash it
# can't mark a file executable, so GNU tar sets the modes itself.
tarball() {
    local name=$1
    chmod 755 "$release/$name" "$release/$name/wtf" "$release/$name/wtfd"
    chmod 644 "$release/$name/LICENSE" "$release/$name/README.txt"
    if tar --version 2>/dev/null | grep -q GNU; then
        (
            cd "$release"
            tar -cf "$name.tar" --owner=0 --group=0 --no-recursion --mode=755 "$name" "$name/wtf" "$name/wtfd"
            tar -rf "$name.tar" --owner=0 --group=0 --mode=644 "$name/LICENSE" "$name/README.txt"
            gzip -9 "$name.tar"
        )
    else
        (cd "$release" && tar -czf "$name.tar.gz" "$name")
    fi
}

scripts/build.sh

rm -rf "$release"
mkdir -p "$release"
for platform in linux-amd64 linux-arm64 windows-amd64 windows-arm64 darwin-amd64 darwin-arm64; do
    os=${platform%-*}
    name=wtf-$version-${platform/darwin/macos}
    ext=""
    if [ "$os" = windows ]; then
        ext=.exe
    fi
    mkdir "$release/$name"
    cp "dist/$platform/wtf$ext" "dist/$platform/wtfd$ext" LICENSE "$release/$name/"
    sed "s/VERSION/$version/" scripts/release-readme.txt >"$release/$name/README.txt"
    if [ "$os" = windows ]; then
        (cd "$release" && zip -r -q "$name.zip" "$name")
        echo "packed $release/$name.zip"
    else
        tarball "$name"
        echo "packed $release/$name.tar.gz"
    fi
    rm -rf "${release:?}/$name"
done
