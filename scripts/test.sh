#!/usr/bin/env bash
# Runs the checks CI runs: formatting, go vet for every platform, and all
# tests. The integration tests only run when WTFD_TEST_DATABASE_NAME is set
# (see README.md, "Tests", and scripts/test-db.sh); otherwise they are
# skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

unformatted=$(gofmt -l .)
if [ -n "$unformatted" ]; then
    echo "These files are not formatted with gofmt:" >&2
    echo "$unformatted" >&2
    exit 1
fi

for os in linux windows darwin; do
    GOOS=$os go vet ./...
done

go test -count=1 ./...
