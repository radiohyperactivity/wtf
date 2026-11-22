#!/usr/bin/env bash
# Builds the app with "flutter build", in app/, stamped with its version
# (from app/pubspec.yaml), the time of the build, and the commit it was
# built from (its ID and time), which the app shows under Account. The
# arguments are flutter build's:
#
#   scripts/app-build.sh windows --release
#   scripts/app-build.sh web --release --no-web-resources-cdn
#
# The commit is git's HEAD. Where there is no git repository (a copy of the
# code on a build machine), WTF_COMMIT and WTF_COMMIT_TIME name it instead:
# the ID and the time, RFC 3339, as "git log -1 --format=%H/%cI" gives them.
# A build made without this script shows none of it. FLUTTER names Flutter
# when "flutter" isn't on the PATH.
set -euo pipefail
cd "$(dirname "$0")/../app"

version=$(sed -n 's/^version: *//p' pubspec.yaml)
commit=${WTF_COMMIT:-$(git rev-parse HEAD 2> /dev/null || true)}
commit_time=${WTF_COMMIT_TIME:-$(git log -1 --format=%cI 2> /dev/null || true)}
"${FLUTTER:-flutter}" build "$@" \
    --dart-define=WTF_VERSION="$version" \
    --dart-define=WTF_BUILD="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --dart-define=WTF_COMMIT="$commit" \
    --dart-define=WTF_COMMIT_TIME="$commit_time"
