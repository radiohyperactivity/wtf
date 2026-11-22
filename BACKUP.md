# Backups of WtF

WtF keeps its data in two places, and a backup needs both:

- **The database,** in PostgreSQL: everything but the contents of files. Backing it up is the PostgreSQL administrator's job, as for any other database on the server.
- **The files directory** (`files-directory` in `wtfd.conf`): the contents of photos and attachments, under their hash. Backing it up is the job of whoever runs `wtfd`.

They belong together: a database restored without its files has photos and attachments that can't be opened.

**A delete is final.** WtF keeps no deleted things and no history, so a backup is the way back from a mistake.

## The database

A dump contains everything in the database: the schema, the data, the grants and `wtfd`'s bookkeeping. Roles are global to the server and not part of a dump; they are recreated with steps 2 and 4 of [Database setup](README.md#database-setup).

### Making a backup

```sh
pg_dump --host=localhost --username=wtf_dba --dbname=wtf \
        --format=custom --file="wtf-$(date +%F).dump"
```

- **`--username=wtf_dba`**: the DBA role owns every object, so it can read everything. `wtf_api` couldn't, because it can't read the tables.
- **`--format=custom`**: a compressed archive for `pg_restore`, which can restore everything or only selected parts. Plain SQL (`--format=plain`) is easier to read but less flexible.
- **Password:** set `PGPASSWORD`, or better, use a password file, which `pg_dump` reads by itself, so the password stays out of scripts and process lists. One line, `localhost:5432:wtf:wtf_dba:<password>`, in `~/.pgpass` (mode 600) on Linux and macOS, or in `%APPDATA%\postgresql\pgpass.conf` of the Windows user that runs it.
- **Version:** use a `pg_dump` at least as new as the server (18). An older `pg_dump` refuses to dump a newer server.

The dump is consistent: it is taken in a single snapshot, while `wtfd serve` keeps running.

**On Windows,** `pg_dump.exe` is in PostgreSQL's `bin` folder, such as `C:\Program Files\PostgreSQL\18\bin`:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\pg_dump.exe" --host=localhost --username=wtf_dba --dbname=wtf `
    --format=custom --file="D:\Backups\wtf\wtf-$(Get-Date -Format yyyy-MM-dd).dump"
```

**Scheduled backups,** for example daily at 03:00 with 30 days kept, from the cron of a user with a `~/.pgpass`:

```cron
0 3 * * *  pg_dump -h localhost -U wtf_dba -d wtf -Fc -f /var/backups/wtf/wtf-$(date +\%F).dump && find /var/backups/wtf -name 'wtf-*.dump' -mtime +30 -delete
```

On Windows, Task Scheduler runs the command above in the same way.

Copy the dumps to another machine as well; a backup on the same disk doesn't survive that disk.

## The files directory

Files are stored under their content hash and never change, so incremental copies are cheap. On Linux and macOS:

```sh
rsync -a /var/lib/wtf/files/ backup-host:/backups/wtf/files/
```

On Windows, in an administrator's PowerShell, as `C:\ProgramData\WtF` is for administrators only:

```powershell
robocopy C:\ProgramData\WtF\files \\backup-host\backups\wtf\files /E
```

- **Database first, files afterwards:** then every file the dump refers to is in the copy. Files that arrive in between are harmless; `wtfd gc` removes any that nothing references.
- **The thumbnails can be left out:** the `thumbnails` directory holds small copies of photos for the apps' lists, which `wtfd` makes again when they are missing. Leave it out with `--exclude /thumbnails/` for `rsync`, or `/XD thumbnails` for `robocopy`.
- **No deleting in the copy:** no `--delete` for `rsync`, no `/MIR` or `/PURGE` for `robocopy`. The files of deleted attachments then stay in the backup after `wtfd gc` removes them from the server, for a restore of an older dump.

## Restoring

Restore into a new, empty database prepared exactly like the original, so that ownership and grants come out right:

1. **Prepare the database**, as a superuser: steps 3 and 4 of [Database setup](README.md#database-setup), with a new database name such as `wtf_restored` (or `wtf` after dropping or renaming the old one). The roles from step 2 must exist.
2. **Restore it** as `wtf_dba`:

   ```sh
   pg_restore --host=localhost --username=wtf_dba --dbname=wtf_restored \
              --single-transaction --exit-on-error wtf-2026-10-24.dump
   ```

   - **`--single-transaction`**: the restore either completes fully or leaves the database empty.
   - **`--exit-on-error`**: stop at the first error instead of carrying on.
3. **Restore the files** into the files directory, with `rsync` or `robocopy` the other way. On Windows, the copied files take their access from the folder, so the service can read them; copy them without their own permissions (`robocopy`'s default, not `/COPYALL` or `/SEC`).
4. **Check it:** `wtfd schema --database-name wtf_restored --dry-run` must report "up to date". After that, `wtfd serve` can use it.

Test a restore now and then. A backup that has never been restored is only a hope.

## Getting one thing back

To get back something deleted by mistake, without losing what changed since, restore the backup *beside* the live database, as `wtf_restored` (steps 1 and 2 above), and look the thing up there, for example with `psql` as `wtf_dba`. Then enter it again through the app or the CLI, or copy its rows across by hand. Its photos and attachments are in the backup of the files directory, under their hash. Drop `wtf_restored` afterwards.
