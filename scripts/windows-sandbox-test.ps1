# Tries the installers on a clean Windows, inside Windows Sandbox, where
# scripts/windows-sandbox-test.sh starts it. Everything here happens in the
# sandbox, which is thrown away afterwards:
#
#   C:\wtf\dist     the installers (read only)
#   C:\wtf\pgsql    PostgreSQL's programs (read only)
#   C:\wtf\scripts  this script (read only)
#   C:\wtf\results  what it found: summary.txt, the logs, and done when it
#                   has finished
#
# It installs the app, then the server: a first install with a new
# database, an upgrade, uninstalling, an existing database with accounts, one
# without (made from wtfd database create --print-sql), and a wrong password.

param(
    [Parameter(Mandatory)] [string] $Version,
    [switch] $StartApp
)

$ErrorActionPreference = 'Stop'
$results = 'C:\wtf\results'
$summary = Join-Path $results 'summary.txt'
$serverSetup = "C:\wtf\dist\release\wtf-$Version-windows-setup.exe"
$appSetup = "C:\wtf\dist\wtf-app-$Version-windows-x64-setup.exe"
$wtfd = 'C:\Program Files\WtF\bin\wtfd.exe'
$data = 'C:\ProgramData\WtF'
$pg = 'C:\wtf\pgsql\bin'
$pgData = 'C:\pgdata'
$script:failures = 0
# Without a timeout, psql and wtfd wait for ever on a connection that gets
# no answer. Both read this setting.
$env:PGCONNECT_TIMEOUT = '10'

Start-Transcript -Path (Join-Path $results 'transcript.txt') | Out-Null

function Note([string] $Line) {
    Add-Content -Path $summary -Value $Line
    Write-Host $Line
}

# Expect records whether what was found is what was wanted.
function Expect([string] $What, [scriptblock] $Test) {
    try {
        $ok = [bool](& $Test)
    } catch {
        $ok = $false
        $What = "$What ($($_.Exception.Message))"
    }
    if ($ok) {
        Note "  ok    $What"
    } else {
        Note "  FAIL  $What"
        $script:failures++
    }
}

function NewPassword {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}

# Setup runs the server's installer without a window, with Params, and
# returns its log.
function Setup([string] $Name, [string[]] $Params) {
    $log = Join-Path $results "$Name.log"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$log") + $Params
    Start-Process -FilePath $serverSetup -ArgumentList $arguments -Wait
    Get-Content -Raw $log
}

function Uninstall([string] $Name) {
    $log = Join-Path $results "$Name.log"
    Start-Process -FilePath 'C:\Program Files\WtF\unins000.exe' -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$log") -Wait
    # The uninstaller finishes from a copy of itself, after it has returned.
    for ($i = 0; $i -lt 60 -and (Test-Path 'C:\Program Files\WtF\unins000.exe'); $i++) { Start-Sleep 1 }
}

# ForgetData removes ProgramData\WtF, for a machine that has never had WtF.
function ForgetData {
    if (Test-Path $data) {
        & takeown.exe /F $data /R /D Y | Out-Null
        & icacls.exe $data /grant Administrators:F /T /C | Out-Null
        Remove-Item -Recurse -Force $data
    }
}

function Health {
    (Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/health' -TimeoutSec 10).status -eq 'ok'
}

function Setting([string] $Key) {
    foreach ($line in Get-Content (Join-Path $data 'wtfd.conf')) {
        if ($line -match "^\s*$Key\s*=\s*(.*?)\s*$") { return $Matches[1] }
    }
}

# Accounts counts the accounts in database Name, as wtfd database check
# says, with the passwords in pgpass.conf.
function Accounts([string] $Name, [string] $Dba, [string] $Api) {
    $env:PGPASSFILE = Join-Path $data 'pgpass.conf'
    $out = & $wtfd database check --database-host localhost --database-name $Name --dba-database-user $Dba --api-database-user $Api 2>&1
    Remove-Item Env:PGPASSFILE
    if ("$out" -match 'Accounts: (\d+)') { [int]$Matches[1] } else { throw "check said: $out" }
}

function FirewallRule {
    $null -ne (Get-NetFirewallRule -DisplayName 'WtF server' -ErrorAction SilentlyContinue)
}

function MachinePath {
    [Environment]::GetEnvironmentVariable('Path', 'Machine')
}

Set-Content -Path $summary -Value "Windows Sandbox: WtF $Version, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

try {
    # The app

    Note ''
    Note 'The app'
    if (Test-Path $appSetup) {
        $runtime = Test-Path 'C:\Windows\System32\vcruntime140_1.dll'
        Note "  (the C++ runtime is $(if ($runtime) { '' } else { 'not ' })installed in Windows here)"
        Start-Process -FilePath $appSetup -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$results\app.log") -Wait
        $app = Join-Path $env:LOCALAPPDATA 'Programs\WtF'
        Expect 'installed for this user' { Test-Path "$app\wtf-app.exe" }
        Expect 'with its C++ runtime beside it' { (Test-Path "$app\msvcp140.dll") -and (Test-Path "$app\vcruntime140.dll") -and (Test-Path "$app\vcruntime140_1.dll") }
        Expect 'in the Start menu' { Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\WtF.lnk" }
        if ($StartApp) {
            $p = Start-Process -FilePath "$app\wtf-app.exe" -PassThru
            Start-Sleep 15
            Expect 'starts, and is still running after 15 seconds' { -not $p.HasExited }
            Expect 'has a window that responds' { $p.Refresh(); $p.Responding -and $p.MainWindowHandle -ne 0 }
            if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        }
        Start-Process -FilePath "$app\unins000.exe" -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait
        for ($i = 0; $i -lt 60 -and (Test-Path "$app\wtf-app.exe"); $i++) { Start-Sleep 1 }
        Expect 'uninstalls' { -not (Test-Path "$app\wtf-app.exe") }
    } else {
        Note "  skipped: $appSetup isn't there"
    }

    # PostgreSQL, on this machine

    Note ''
    Note 'PostgreSQL'
    $adminPassword = NewPassword
    $pwfile = 'C:\pgpw.txt'
    Set-Content -Path $pwfile -Value $adminPassword -Encoding ascii
    & "$pg\initdb.exe" -D $pgData -U postgres --pwfile=$pwfile --auth=scram-sha-256 -E UTF8 --locale=C *> "$results\initdb.txt"
    Remove-Item $pwfile
    # The server that pg_ctl starts inherits pg_ctl's output, so with the
    # output read through a pipe, as "& pg_ctl" does, PowerShell waits for
    # the server to stop. With the output going to files, only pg_ctl is
    # waited for.
    $pgCtl = Start-Process -FilePath "$pg\pg_ctl.exe" -ArgumentList 'start', '-D', $pgData, '-l', 'C:\postgres.log', '-w' `
        -RedirectStandardOutput "$results\pg_ctl.txt" -RedirectStandardError "$results\pg_ctl-errors.txt" `
        -WindowStyle Hidden -PassThru
    # Without reading Handle first, ExitCode comes back empty.
    $null = $pgCtl.Handle
    if (-not $pgCtl.WaitForExit(120000)) { throw 'pg_ctl start took more than 2 minutes' }
    if ($pgCtl.ExitCode -ne 0) { throw "pg_ctl start failed with $($pgCtl.ExitCode)" }
    # What localhost resolves to, and whether PostgreSQL's port answers on
    # each address, for when the connection below fails.
    & {
        Resolve-DnsName localhost -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String
        foreach ($address in '127.0.0.1', '::1') {
            $client = New-Object System.Net.Sockets.TcpClient([System.Net.IPAddress]::Parse($address).AddressFamily)
            try {
                if ($client.ConnectAsync($address, 5432).Wait(5000)) {
                    "port 5432 on ${address}: answers"
                } else {
                    "port 5432 on ${address}: no answer within 5 seconds"
                }
            } catch {
                "port 5432 on ${address}: $($_.Exception.InnerException.Message)"
            } finally {
                $client.Dispose()
            }
        }
        Get-NetTCPConnection -State Listen -LocalPort 5432 -ErrorAction SilentlyContinue | Format-Table LocalAddress, LocalPort, OwningProcess -AutoSize | Out-String
    } *> "$results\network.txt"
    Copy-Item C:\postgres.log $results -ErrorAction SilentlyContinue
    $env:PGPASSWORD = $adminPassword
    $version = & "$pg\psql.exe" -h localhost -U postgres -d postgres -Atc 'SHOW server_version'
    Remove-Item Env:PGPASSWORD
    Expect "running, version $version" { $version -like '18*' }

    # A first install, with a new database

    Note ''
    Note 'First install, a new database, open to the network'
    $env:WTFD_ADMIN_DATABASE_PASSWORD = $adminPassword
    $log = Setup '1-new' @('/database=new', '/account=first@example.org', '/listen=network', '/firewall=yes')
    Remove-Item Env:WTFD_ADMIN_DATABASE_PASSWORD
    Expect 'set up' { $log -match 'WtF is set up\.' }
    Expect 'the account''s password is kept out of the log' { $log -match '\(shown above\)' }
    Expect 'the service runs, from startup on' { $s = Get-Service wtfd; $s.Status -eq 'Running' -and $s.StartType -eq 'Automatic' }
    Expect 'it answers' { Health }
    Expect 'listens on the network' { (Setting 'listen') -eq '0.0.0.0:8080' }
    Expect 'runs gc every night at 02:00' { (Setting 'gc') -eq '02:00' }
    Expect 'with a firewall rule' { FirewallRule }
    Expect 'the programs are on the PATH' { (MachinePath) -like '*C:\Program Files\WtF\bin*' }
    Expect 'one account' { (Accounts 'wtf' 'wtf_dba' 'wtf_api') -eq 1 }
    Expect 'the service may read pgpass.conf' { (& icacls.exe (Join-Path $data 'pgpass.conf')) -match 'NT SERVICE\\wtfd' }
    Expect 'other users may not' { -not ((& icacls.exe (Join-Path $data 'pgpass.conf')) -match 'BUILTIN\\Users') }
    & icacls.exe $data /T *> "$results\1-new-access.txt"
    $settings = Get-Content -Raw (Join-Path $data 'wtfd.conf')

    # An upgrade, which asks nothing

    Note ''
    Note 'Upgrade, keeping the settings'
    $log = Setup '2-upgrade' @()
    Expect 'set up' { $log -match 'WtF is set up\.' }
    Expect 'the settings are as they were' { (Get-Content -Raw (Join-Path $data 'wtfd.conf')) -eq $settings }
    Expect 'the service runs again' { (Get-Service wtfd).Status -eq 'Running' }
    Expect 'it answers' { Health }
    Expect 'the firewall rule stays' { FirewallRule }
    Expect 'still one account' { (Accounts 'wtf' 'wtf_dba' 'wtf_api') -eq 1 }

    # The passwords, for installing on a machine that has never had WtF, and
    # a database made by hand from wtfd database create --print-sql.
    $passwords = @{}
    foreach ($line in Get-Content (Join-Path $data 'pgpass.conf')) {
        $fields = $line -split ':'
        if ($fields.Count -ge 5) { $passwords[$fields[3]] = $fields[4] }
    }
    $dba2Password = NewPassword
    $api2Password = NewPassword
    $sql = (& $wtfd database create --print-sql --database-name wtf2 --dba-database-user wtf2_dba --api-database-user wtf2_api) -join "`n"
    $sql = $sql -replace '\\password "?wtf2_dba"?', "ALTER ROLE wtf2_dba PASSWORD '$dba2Password';"
    $sql = $sql -replace '\\password "?wtf2_api"?', "ALTER ROLE wtf2_api PASSWORD '$api2Password';"
    Set-Content -Path C:\wtf2.sql -Value $sql -Encoding ascii
    $env:PGPASSWORD = $adminPassword
    & "$pg\psql.exe" -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -f C:\wtf2.sql *> "$results\wtf2-sql.txt"
    $made = $LASTEXITCODE -eq 0
    Remove-Item Env:PGPASSWORD

    # Uninstalling

    Note ''
    Note 'Uninstall'
    Uninstall '3-uninstall'
    Expect 'the service is gone' { $null -eq (Get-Service wtfd -ErrorAction SilentlyContinue) }
    Expect 'the firewall rule is gone' { -not (FirewallRule) }
    Expect 'the programs are gone' { -not (Test-Path 'C:\Program Files\WtF\bin\wtfd.exe') }
    Expect 'and off the PATH' { -not ((MachinePath) -like '*C:\Program Files\WtF\bin*') }
    Expect 'the data stays' { (Test-Path (Join-Path $data 'wtfd.conf')) -and (Test-Path (Join-Path $data 'pgpass.conf')) }

    # An existing database, with accounts, on a machine without WtF

    Note ''
    Note 'First install, an existing database with an account, this machine only'
    ForgetData
    $env:WTFD_DBA_DATABASE_PASSWORD = $passwords['wtf_dba']
    $env:WTFD_API_DATABASE_PASSWORD = $passwords['wtf_api']
    $log = Setup '4-existing' @('/database=existing', '/account=second@example.org', '/listen=local')
    Remove-Item Env:WTFD_DBA_DATABASE_PASSWORD, Env:WTFD_API_DATABASE_PASSWORD
    Expect 'set up' { $log -match 'WtF is set up\.' }
    Expect 'no second account, as there is one' { $log -match 'has accounts already' }
    Expect 'still one account' { (Accounts 'wtf' 'wtf_dba' 'wtf_api') -eq 1 }
    Expect 'the service runs' { (Get-Service wtfd).Status -eq 'Running' }
    Expect 'it answers' { Health }
    Expect 'listens on this machine only' { (Setting 'listen') -eq '127.0.0.1:8080' }
    Expect 'no firewall rule' { -not (FirewallRule) }
    Uninstall '4-uninstall'
    ForgetData

    # An existing database without accounts

    Note ''
    Note 'First install, an existing database without accounts (made with --print-sql)'
    Expect 'the database was made by hand' { $made }
    $env:WTFD_DBA_DATABASE_PASSWORD = $dba2Password
    $env:WTFD_API_DATABASE_PASSWORD = $api2Password
    $log = Setup '5-existing-empty' @('/database=existing', '/dbname=wtf2', '/dbauser=wtf2_dba', '/apiuser=wtf2_api', '/account=third@example.org')
    Remove-Item Env:WTFD_DBA_DATABASE_PASSWORD, Env:WTFD_API_DATABASE_PASSWORD
    Expect 'set up' { $log -match 'WtF is set up\.' }
    Expect 'the first account is made' { (Accounts 'wtf2' 'wtf2_dba' 'wtf2_api') -eq 1 }
    Expect 'it answers' { Health }
    Uninstall '5-uninstall'
    ForgetData

    # A wrong password

    Note ''
    Note 'A wrong password for an existing database'
    $env:WTFD_DBA_DATABASE_PASSWORD = 'not the password'
    $env:WTFD_API_DATABASE_PASSWORD = $passwords['wtf_api']
    $log = Setup '6-wrong-password' @('/database=existing')
    Remove-Item Env:WTFD_DBA_DATABASE_PASSWORD, Env:WTFD_API_DATABASE_PASSWORD
    # The check comes before anything is installed, so a silent setup stops
    # there, and the programs never arrive.
    Expect 'not set up' { $log -match 'aborting' -and -not (Test-Path $wtfd) }
    Expect 'says the password is wrong' { $log -match 'the password for wtf_dba is wrong' }
    Expect 'no service' { $null -eq (Get-Service wtfd -ErrorAction SilentlyContinue) }
    Expect 'no settings written' { -not (Test-Path (Join-Path $data 'wtfd.conf')) -or -not ((Get-Content -Raw (Join-Path $data 'wtfd.conf')) -match 'database-name') }
} catch {
    Note ''
    Note "  FAIL  stopped: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
    $script:failures++
} finally {
    Copy-Item C:\postgres.log $results -ErrorAction SilentlyContinue
    Note ''
    if ($script:failures -eq 0) { Note 'All passed.' } else { Note "$($script:failures) failed." }
    Stop-Transcript | Out-Null
    Set-Content -Path (Join-Path $results 'done') -Value $script:failures
}
