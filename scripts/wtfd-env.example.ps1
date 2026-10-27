# wtfd environment for PowerShell. Copy this file to a place git doesn't
# track (it holds your own settings), fill in your values, and dot-source
# it so the variables stay in your session:
#   . C:\path\to\wtfd-env.ps1
# Lines starting with # show the defaults; uncomment the ones you change.

# --- Database connection (all commands) ---
$env:WTFD_DATABASE_HOST = 'db.example.lan'     # default: localhost
# $env:WTFD_DATABASE_PORT    = '5432'          # default: 5432
# $env:WTFD_DATABASE_NAME    = 'wtf'           # default: wtf
# $env:WTFD_DATABASE_SSLMODE = 'prefer'        # disable, allow, prefer, require, verify-ca, verify-full

# --- Roles ---
# $env:WTFD_DBA_DATABASE_USER = 'wtf_dba'      # schema owner (schema, account, history, gc)
# $env:WTFD_API_DATABASE_USER = 'wtf_api'      # role the REST API connects as (serve)

# --- Passwords: read from files outside the project, so they never sit in a script ---
$env:WTFD_DBA_DATABASE_PASSWORD = (Get-Content 'C:\path\to\wtf-dba-password' -Raw).Trim()
$env:WTFD_API_DATABASE_PASSWORD = (Get-Content 'C:\path\to\wtf-api-password' -Raw).Trim()

# --- Attachment files (serve, gc) ---
$env:WTFD_FILES_DIRECTORY = 'C:\path\to\wtf-files'   # required, no default

# --- serve ---
# $env:WTFD_LISTEN                       = '127.0.0.1:8080'  # address:port
# $env:WTFD_API_DATABASE_MAX_CONNECTIONS = '10'              # connection pool size
# $env:WTFD_MAX_REQUEST_BODY_SIZE        = '1048576'         # bytes (1 MiB)
# $env:WTFD_MAX_ATTACHMENT_SIZE          = '104857600'       # bytes (100 MiB)
# $env:WTFD_WEB_ROOT                     = 'C:\path\to\web'  # the web app (a Flutter web build)

# --- gc ---
# $env:WTFD_GC_MIN_AGE = '1h'                  # Go duration: never remove files younger than this

# --- Integration tests (go test ./internal/integration/) ---
# $env:WTFD_TEST_DATABASE_NAME = 'wtf_test'    # must end in _test: the tests delete its data
# $env:WTFD_TEST_DATABASE_HOST = 'db.example.lan'
