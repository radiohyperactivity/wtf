#!/usr/bin/env bash
# Builds the Windows app and its installer, on Windows in Git Bash:
#
#   dist/wtf-app-<version>-windows-x64-setup.exe
#
# The version is the app's, from app/pubspec.yaml. The installer includes the
# Microsoft C++ runtime, from Visual Studio, so the app starts on a PC that
# doesn't have it. It needs Flutter (FLUTTER names it when "flutter" isn't on
# the PATH) and Inno Setup (ISCC names its ISCC.exe when it isn't installed
# where Inno Setup puts it).
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

# The newest C++ runtime of any Visual Studio that is installed: each path
# is sorted by its version, the folder under MSVC.
crt=$(ls -d "$PROGRAMFILES/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT \
    "$PROGRAMFILES (x86)/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT \
    2>/dev/null | sed 's|.*/MSVC/\([^/]*\)/.*|\1\t&|' | sort -V | tail -1 | cut -f2 || true)
if [ -z "$crt" ]; then
    echo "The Visual Studio C++ runtime wasn't found (VC/Redist/MSVC)" >&2
    exit 1
fi

scripts/app-build.sh windows --release

build=app/build/windows/x64/runner/Release
cp "$crt/msvcp140.dll" "$crt/vcruntime140.dll" "$crt/vcruntime140_1.dll" "$build/"

mkdir -p dist
# Git Bash would otherwise take ISCC's options, which start with /, for
# paths, and change them.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$iscc" /Q \
    "/DAppVersion=$version" \
    "/DSourceDir=$(cygpath -w "$PWD/$build")" \
    "/DOutputDir=$(cygpath -w "$PWD/dist")" \
    "$(cygpath -w scripts/windows-app-installer.iss)"
echo "built dist/wtf-app-$version-windows-x64-setup.exe"
