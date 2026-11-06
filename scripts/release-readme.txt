WtF - Where to Find, version VERSION

  wtfd   the server: the REST API, with the web app built in
  wtf    the command-line tool, for using WtF from a terminal

WtF needs PostgreSQL 18 or newer.

Getting started

  Windows: open PowerShell as an administrator, go to this folder, and run
  .\wtfd.exe install. It installs both programs, makes the database or
  connects to the one there is, and writes the settings.

  Linux and macOS: "wtfd database create" makes the database, and
  "wtfd serve" runs the server. See README.md for the rest:
  https://github.com/radiohyperactivity/wtf

Run wtfd or wtf without arguments for what they can do.

Licence: GNU Affero General Public License, version 3 (LICENSE).
