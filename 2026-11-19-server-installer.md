# An installer for the server on Windows – plan

**Status: built (2026-11-19): steps 1–3 and 5.** A first install is still to be tried, on another machine, and an upgrade on this PC.

## Why

Setting WtF up on Windows is `wtfd install` and `wtfd service install` in an administrator's PowerShell, answering questions in the terminal, and the same again for every upgrade. The installer for the Windows app showed how much easier one file is. This is the same for the server: one setup file, with every question on its own page, and nothing to do in a terminal, unless you want to.

## How it works

1. **One setup file, `wtf-<version>-windows-setup.exe`,** with `wtfd` and `wtf` for x64 and ARM64; it installs the ones for the machine's processor.
2. **The installer asks everything on its own pages,** before installing anything: the database, the address `wtfd` listens on, the service and the firewall.
3. **It runs `wtfd install` and `wtfd service install` without a window,** with the settings as flags, which aren't secret; `wtfd install` writes `wtfd.conf`, and the database's settings in it only once the database works, so that a setup that stopped half-way isn't taken for an upgrade the next time. The passwords go to `pgpass.conf` (decisions 14 and 15). The output goes to a log, which the installer shows when a step fails.
4. **An upgrade asks nothing:** `wtfd.conf` is there, so the installer shows what it will keep, and installs.

## Decisions

### What it does

1. **One setup file for both processors** (x64 and ARM64), named like the zips: `wtf-<version>-windows-setup.exe`. **The zips stay** in the release *(yours)*, for setting up by hand or from a script.
2. **It needs an administrator,** as `wtfd install` does: it writes to Program Files and ProgramData, and sets up a service. Windows asks (UAC); unsigned, the prompt says "Unknown publisher".
3. **The programs go in `Program Files\WtF\bin`,** as now, put there by the installer itself, so that Windows knows them: an uninstaller under Settings → Apps, and a new version installing over the old one. Before copying them, it stops the `wtfd` service if it runs.
4. **No check for PostgreSQL on the machine** *(yours)*: the database may be on another one, and `wtfd` checks the server's version when it connects. The database's host is `localhost` to begin with.
5. **The service is ticked by default** on a first install *(yours)*. On an upgrade, a service that was there is brought up to date and started again.
6. **Uninstalling** removes the service (as `wtfd service uninstall` does: its access, the firewall rule, the Event Log source), the programs, and their folder from the PATH. **It leaves the data:** `ProgramData\WtF` (the settings, the passwords and the files) and the database. The last page says where they are, and that deleting them is up to you.

### The pages

7. **Upgrade or not:** when `wtfd.conf` is there, one page shows its settings (database, listen address, files directory) and says they are kept, with **Change the settings** for going through the pages below, the file's values as the defaults (as `--reconfigure`).
8. **The database: there already, or a new one.**
   - **There already:** the server and port, the database's name, and WtF's two roles with their passwords.
   - **A new one:** the server and port, a PostgreSQL administrator (`postgres`) and its password; the database's and the roles' names, with `wtfd database create`'s defaults. The roles get passwords that `wtfd` generates.
9. **The database page is tried when you press Next:** the installer runs `wtfd` without a window to connect with what was typed, so a wrong password or server shows there, where it can be put right, not at the end.
10. **The first account,** for a new database, and for one that was there but has no accounts yet (made by a database administrator with `wtfd database create --print-sql`, say): its email. `wtfd account create` makes it, and the last page shows its password once, in a box it can be copied from, saying to change it after logging in.
11. **The server:** this machine only (`127.0.0.1`) or the network (`0.0.0.0`), and the port (8080). The files directory, `ProgramData\WtF\files` unless another is chosen (another drive, say).
12. **The service and the firewall:** **Run WtF as a Windows service** (ticked), and **Let other machines reach it through Windows Firewall**, ticked when it listens on the network, and off otherwise.
13. **The last page** says what was done, with the address to open (`http://<this machine>:8080`), and the log when something failed. Nothing is started but the service.

### The passwords

14. **The roles' passwords end up in `pgpass.conf`,** where `wtfd` reads them from then on *(yours)*. The installer gives them to `wtfd install` in its environment, as decision 15, and `wtfd install` writes them there, as it does for passwords typed in: after it has made `ProgramData\WtF` for administrators only, so they are never readable by other users. That way one program writes the file, not two (changed while building).
15. **The PostgreSQL administrator's password,** for a new database, isn't kept: the installer gives it to `wtfd` in its environment (`PGPASSWORD`) for that one run, which only the same administrator can read, and never on a command line, which every user can see, or on disk.
16. **The same for trying the database page** (decision 9): the passwords typed are given to `wtfd` in its environment, as nothing is written before Install is pressed.

### In `wtfd`

17. **What the installer needs of `wtfd`,** none of which changes using it in a terminal:
    - `wtfd install --database existing|new`, which with the database's flags asks nothing, also without a terminal. The passwords come from the environment: `WTFD_DBA_DATABASE_PASSWORD` and `WTFD_API_DATABASE_PASSWORD`, which `wtfd` had already, and the new `WTFD_ADMIN_DATABASE_PASSWORD` for the administrator. The roles of a new database get generated passwords. `--first-account` makes the first account in a database that exists too, when it has none.
    - `wtfd service install --firewall yes|no`, where it only printed the `netsh` command without a terminal.
    - `wtfd database check [--new [--server-only]]`, which tries the settings, changes nothing, says what is wrong in plain words, and prints the server's version, whether the schema is up to date, and how many accounts there are.
    - `wtfd install` may run from the installed copy (`Program Files\WtF\bin`), which the installer has put there, and then does everything but copy the programs, as it does now.

### Building

18. **`scripts/windows-server-installer.sh`,** in Git Bash on Windows, after `scripts/release.sh`, from its `dist/windows-amd64` and `dist/windows-arm64`, with `scripts/windows-server-installer.iss`, into `dist/release/`, beside the zips. `scripts/windows-installer.sh` and its `.iss` become `windows-app-installer.*`, so the two aren't confused.

### Trying it

19. **A first install is tried on another machine,** by you *(yours)*; an upgrade is tried on this PC.

## Steps

1. This plan.
2. `wtfd`: the flags and the check of decision 17; tests.
3. The installer: its script and the build script; the app's renamed.
4. Trying it: an upgrade on this PC; a first install on another machine, by you.
5. The documents: README.md ("Installing on Windows"), BUILDING.md, WTFD.md.
