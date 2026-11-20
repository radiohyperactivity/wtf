#!/usr/bin/env bash
# Builds the installer of the server, wtfd with wtf, for Windows on x64 and
# ARM64, on Windows in Git Bash:
#
#   dist/release/wtf-<version>-windows-setup.exe
#
# It takes the programs scripts/build.sh made in dist/windows-amd64 and
# dist/windows-arm64, so it runs after scripts/release.sh (or build.sh),
# beside the release's zips. The version is the app's, from
# app/pubspec.yaml. It needs Inno Setup (ISCC names its ISCC.exe when it
# isn't installed where Inno Setup puts it).
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml | tr -d '\r')

iscc=${ISCC:-}
if [ -z "$iscc" ]; then
    for dir in "$LOCALAPPDATA/Programs/Inno Setup 7" "$PROGRAMFILES/Inno Setup 7" \
        "$LOCALAPPDATA/Programs/Inno Setup 6" "${PROGRAMFILES} (x86)/Inno Setup 6"; do
        if [ -f "$dir/ISCC.exe" ]; then
            iscc=$dir/ISCC.exe
            break
        fi
    done
fi
if [ -z "$iscc" ]; then
    echo "Inno Setup isn't installed; set ISCC to its ISCC.exe" >&2
    exit 1
fi

for platform in windows-amd64 windows-arm64; do
    for program in wtfd.exe wtf.exe; do
        if [ ! -f "dist/$platform/$program" ]; then
            echo "dist/$platform/$program isn't there; run scripts/release.sh first" >&2
            exit 1
        fi
    done
done

mkdir -p dist/release
# Git Bash would otherwise take ISCC's options, which start with /, for
# paths, and change them.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$iscc" /Q \
    "/DAppVersion=$version" \
    "/DDistDir=$(cygpath -w "$PWD/dist")" \
    "/DOutputDir=$(cygpath -w "$PWD/dist/release")" \
    "$(cygpath -w scripts/windows-server-installer.iss)"
echo "built dist/release/wtf-$version-windows-setup.exe"
