#!/usr/bin/env bash
# Builds the app with "flutter build", in app/, stamped with its version
# (from app/pubspec.yaml) and the time of the build, which the app shows
# under Account. The arguments are flutter build's:
#
#   scripts/app-build.sh windows --release
#   scripts/app-build.sh web --release --no-web-resources-cdn
#
# A build made without this script shows neither. FLUTTER names Flutter
# when "flutter" isn't on the PATH.
set -euo pipefail
cd "$(dirname "$0")/../app"

version=$(sed -n 's/^version: *//p' pubspec.yaml)
"${FLUTTER:-flutter}" build "$@" \
    --dart-define=WTF_VERSION="$version" \
    --dart-define=WTF_BUILD="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
