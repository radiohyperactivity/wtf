#!/usr/bin/env bash
# Builds wtf and wtfd for every supported platform into dist/<os>-<arch>/.
# Go builds for other systems from any machine, so one run on Linux,
# Windows (Git Bash) or macOS produces them all; linux-arm64 also runs on
# a Raspberry Pi with a 64-bit OS.
set -euo pipefail
cd "$(dirname "$0")/.."

for target in linux/amd64 linux/arm64 windows/amd64 windows/arm64 darwin/amd64 darwin/arm64; do
    os=${target%/*}
    arch=${target#*/}
    ext=""
    if [ "$os" = windows ]; then
        ext=.exe
    fi
    out=dist/$os-$arch
    for cmd in wtf wtfd; do
        CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -o "$out/$cmd$ext" "./cmd/$cmd"
    done
    echo "built $out"
done
