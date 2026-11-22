#!/usr/bin/env bash
# Tries the Windows installers on a clean Windows, in Windows Sandbox, without
# anyone clicking: scripts/windows-sandbox-test.ps1 runs in the sandbox and
# installs the app, then the server, with a PostgreSQL of its own, in the
# cases it lists. In Git Bash on Windows, after scripts/release.sh,
# scripts/windows-server-installer.sh and scripts/windows-app-installer.sh:
#
#   scripts/windows-sandbox-test.sh [--start-app]
#
# --start-app also starts the app in the sandbox, to see that it opens.
#
# Windows Sandbox must be turned on (as an administrator, then a restart):
#   Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM
#
# PostgreSQL's programs are downloaded once, into local/sandbox/. What the
# test found goes in dist/sandbox-test/: summary.txt, and the installers' logs.
set -euo pipefail
cd "$(dirname "$0")/.."

start_app=
case "${1:-}" in
    --start-app) start_app=-StartApp ;;
    "") ;;
    *) echo "usage: scripts/windows-sandbox-test.sh [--start-app]" >&2; exit 2 ;;
esac

sandbox="$SYSTEMROOT/System32/WindowsSandbox.exe"
if [ ! -f "$sandbox" ]; then
    echo "Windows Sandbox isn't turned on: as an administrator, run" >&2
    echo "  Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM" >&2
    echo "and restart Windows" >&2
    exit 1
fi
if tasklist //FI "IMAGENAME eq WindowsSandboxRemoteSession.exe" | grep -qi WindowsSandbox; then
    echo "a Windows Sandbox is running already, and there can be only one: close it first" >&2
    exit 1
fi

version=$(sed -n 's/^version: *\([^+]*\).*/\1/p' app/pubspec.yaml | tr -d '\r')
if [ ! -f "dist/release/wtf-$version-windows-setup.exe" ]; then
    echo "dist/release/wtf-$version-windows-setup.exe isn't there; run scripts/windows-server-installer.sh first" >&2
    exit 1
fi
if [ ! -f "dist/wtf-app-$version-windows-x64-setup.exe" ]; then
    echo "note: dist/wtf-app-$version-windows-x64-setup.exe isn't there, so the app is skipped" >&2
fi

# PostgreSQL's programs, without pgAdmin, StackBuilder, the documentation
# and the headers, which the test doesn't need.
pg_version=18.7
pg_url="https://sbp.enterprisedb.com/getfile.jsp?fileid=1260725"
cache=local/sandbox
if [ ! -f "$cache/pgsql/bin/postgres.exe" ]; then
    mkdir -p "$cache"
    zip="$cache/postgresql-$pg_version-windows-x64-binaries.zip"
    [ -f "$zip" ] || curl -sSfL -o "$zip" "$pg_url"
    rm -rf "$cache/pgsql"
    unzip -q "$zip" -d "$cache"
    rm -rf "$cache/pgsql/pgAdmin 4" "$cache/pgsql/StackBuilder" "$cache/pgsql/doc" "$cache/pgsql/include"
fi
# PostgreSQL needs the C++ runtime, which a clean Windows doesn't have: it
# gets its own copy beside its programs, so that Windows itself stays without
# one, for trying the app.
if [ ! -f "$cache/pgsql/bin/vcruntime140.dll" ]; then
    crt=$(ls -d "$PROGRAMFILES/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT \
        "$PROGRAMFILES (x86)/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT \
        2>/dev/null | sed 's|.*/MSVC/\([^/]*\)/.*|\1\t&|' | sort -V | tail -1 | cut -f2 || true)
    if [ -z "$crt" ]; then
        echo "The Visual Studio C++ runtime wasn't found (VC/Redist/MSVC)" >&2
        exit 1
    fi
    cp "$crt"/*.dll "$cache/pgsql/bin/"
fi

results=dist/sandbox-test
rm -rf "$results"
mkdir -p "$results"

win() { cygpath -w "$PWD/$1"; }
config="$results/test.wsb"
cat > "$config" <<EOF
<Configuration>
  <Networking>Disable</Networking>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(win dist)</HostFolder>
      <SandboxFolder>C:\\wtf\\dist</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(win "$cache/pgsql")</HostFolder>
      <SandboxFolder>C:\\wtf\\pgsql</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(win scripts)</HostFolder>
      <SandboxFolder>C:\\wtf\\scripts</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(win "$results")</HostFolder>
      <SandboxFolder>C:\\wtf\\results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\wtf\\scripts\\windows-sandbox-test.ps1 -Version $version $start_app</Command>
  </LogonCommand>
</Configuration>
EOF

echo "starting Windows Sandbox; the test takes a few minutes"
"$sandbox" "$(win "$config")" &

# Waits for the test to finish, for at most 30 minutes.
for _ in $(seq 1 360); do
    [ -f "$results/done" ] && break
    sleep 5
done

# Closes the sandbox, which throws it away.
taskkill //F //IM WindowsSandboxRemoteSession.exe >/dev/null 2>&1 || true
taskkill //F //IM WindowsSandbox.exe >/dev/null 2>&1 || true

if [ ! -f "$results/done" ]; then
    echo "the test didn't finish within 30 minutes; what it found so far is in $results" >&2
    [ -f "$results/summary.txt" ] && cat "$results/summary.txt"
    exit 1
fi
cat "$results/summary.txt"
echo
echo "the logs are in $results"
[ "$(tr -d '\r\n ' < "$results/done")" = 0 ]
