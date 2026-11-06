#!/usr/bin/env bash
# Builds wtf and wtfd for every supported platform into dist/<os>-<arch>/.
# Go builds for other systems from any machine, so one run on Linux,
# Windows (Git Bash) or macOS produces them all; linux-arm64 also runs on
# a Raspberry Pi with a 64-bit OS.
#
# wtfd has the web app built in: the Flutter web build of app/, made once
# here, copied to internal/webapp/dist and embedded with the build tag
# "webapp". That needs Flutter: FLUTTER names it when "flutter" isn't on
# the PATH (FLUTTER=~/fvm/default/bin/flutter). NO_WEB_APP=1 builds wtfd
# without it, as "go install" does.
set -euo pipefail
cd "$(dirname "$0")/.."

tags=""
if [ -z "${NO_WEB_APP:-}" ]; then
    # No CDN: wtfd's Content Security Policy only allows its own files.
    (cd app && "${FLUTTER:-flutter}" build web --release --no-web-resources-cdn)
    rm -rf internal/webapp/dist
    cp -r app/build/web internal/webapp/dist
    tags=webapp
    echo "built the web app"
fi

# When it was built, for wtfd's /api/health (internal/buildinfo); Go
# records the commit itself.
ldflags="-X github.com/radiohyperactivity/wtf/internal/buildinfo.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for target in linux/amd64 linux/arm64 windows/amd64 windows/arm64 darwin/amd64 darwin/arm64; do
    os=${target%/*}
    arch=${target#*/}
    ext=""
    if [ "$os" = windows ]; then
        ext=.exe
    fi
    out=dist/$os-$arch
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -o "$out/wtf$ext" ./cmd/wtf
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -tags "$tags" -ldflags "$ldflags" -o "$out/wtfd$ext" ./cmd/wtfd
    echo "built $out"
done
