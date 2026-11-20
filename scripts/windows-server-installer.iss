; The installer of the server, wtfd, with wtf, for Inno Setup
; (scripts/windows-server-installer.sh builds the programs' release and runs
; this). It puts the programs in Program Files\WtF\bin itself, and leaves the
; rest to them: it asks everything on its own pages, tries the database
; with "wtfd database check" before going on, and then runs "wtfd install"
; and "wtfd service install" without a window, with the settings as flags
; and the passwords in their environment, never on a command line. On an
; upgrade, wtfd.conf has the settings, and nothing is asked.
;
; scripts/windows-server-installer.sh defines:
;   AppVersion  the version, from app/pubspec.yaml
;   DistDir     dist\, with windows-amd64\ and windows-arm64\ from scripts/build.sh
;   OutputDir   where the installer goes

#ifndef AppVersion
  #error AppVersion is not defined; run scripts/windows-server-installer.sh
#endif

[Setup]
; Windows knows the server by this, so a new version replaces the old one.
; It must never change.
AppId={{53E2FC43-0415-471C-9DA0-6BA16477AF91}
AppName=WtF server
AppVersion={#AppVersion}
AppVerName=WtF server {#AppVersion}
AppPublisher=Bård Bjerke Johannessen
AppPublisherURL=https://github.com/radiohyperactivity/wtf
AppCopyright=Copyright (C) 2026 Bård Bjerke Johannessen
VersionInfoVersion={#AppVersion}
; Where wtfd install expects the programs, and the service runs them from.
DefaultDirName={commonpf}\WtF
DisableDirPage=yes
UsePreviousAppDir=no
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
ChangesEnvironment=yes
; The service is stopped before the programs are replaced (PrepareToInstall).
CloseApplications=no
LicenseFile=..\LICENSE
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\bin\wtfd.exe
UninstallDisplayName=WtF server
OutputDir={#OutputDir}
OutputBaseFilename=wtf-{#AppVersion}-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#DistDir}\windows-arm64\wtfd.exe"; DestDir: "{app}\bin"; Check: IsArm64; Flags: ignoreversion
Source: "{#DistDir}\windows-arm64\wtf.exe"; DestDir: "{app}\bin"; Check: IsArm64; Flags: ignoreversion
Source: "{#DistDir}\windows-amd64\wtfd.exe"; DestDir: "{app}\bin"; Check: not IsArm64; Flags: ignoreversion solidbreak
Source: "{#DistDir}\windows-amd64\wtf.exe"; DestDir: "{app}\bin"; Check: not IsArm64; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
; For trying the database before anything is installed; the x64 one runs on
; ARM64 too. The same file as above, so it is stored once.
Source: "{#DistDir}\windows-amd64\wtfd.exe"; DestName: "wtfd-check.exe"; Flags: dontcopy

[UninstallRun]
Filename: "{app}\bin\wtfd.exe"; Parameters: "service uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "ServiceUninstall"

[UninstallDelete]
; What wtfd install moved aside when it replaced a running program.
Type: files; Name: "{app}\bin\*.old-*"

[Code]
const
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

var
  UpgradePage: TInputOptionWizardPage;
  DatabasePage: TInputOptionWizardPage;
  NewServerPage: TInputQueryWizardPage;
  NewNamesPage: TInputQueryWizardPage;
  ExistingServerPage: TInputQueryWizardPage;
  ExistingRolesPage: TInputQueryWizardPage;
  AccountPage: TInputQueryWizardPage;
  ServerPage: TWizardPage;
  LocalRadio, NetworkRadio: TNewRadioButton;
  PortEdit, FilesEdit: TNewEdit;
  ServicePage: TInputOptionWizardPage;
  ResultPage: TOutputMsgMemoWizardPage;

  Settings: TArrayOfString; { wtfd.conf's lines, on an upgrade }
  Upgrade: Boolean;         { wtfd.conf is there }
  ServiceExisted: Boolean;  { the wtfd service was set up before }
  Accounts: Integer;        { in an existing database, from the check }
  Output: String;           { what the last wtfd run said }
  StepLog: String;          { what wtfd install and service install said }
  Failed: Boolean;
  AccountPassword: String;

function SetEnvironmentVariable(Name, Value: String): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

{ The settings and the steps }

function Setting(Key, Default: String): String;
var
  I, P: Integer;
  Line: String;
begin
  Result := Default;
  for I := 0 to GetArrayLength(Settings) - 1 do
  begin
    Line := Trim(Settings[I]);
    P := Pos('=', Line);
    if (P > 0) and (Copy(Line, 1, 1) <> '#') and (Trim(Copy(Line, 1, P - 1)) = Key) then
      Result := Trim(Copy(Line, P + 1, Length(Line)));
  end;
end;

{ ListenPort is the port of an address such as 127.0.0.1:8080. }
function ListenPort(Listen: String): String;
var
  I: Integer;
begin
  Result := '8080';
  for I := Length(Listen) downto 1 do
    if Listen[I] = ':' then
    begin
      Result := Copy(Listen, I + 1, Length(Listen));
      Exit;
    end;
end;

{ KeepSettings: an upgrade that keeps wtfd.conf as it is, and asks nothing. }
function KeepSettings: Boolean;
begin
  Result := Upgrade and not UpgradePage.Values[0];
end;

function NewDatabase: Boolean;
begin
  Result := DatabasePage.Values[1];
end;

function Listen: String;
begin
  if NetworkRadio.Checked then
    Result := '0.0.0.0:' + Trim(PortEdit.Text)
  else
    Result := '127.0.0.1:' + Trim(PortEdit.Text);
end;

function ServiceExists: Boolean;
var
  Code: Integer;
begin
  Result := Exec(ExpandConstant('{sys}\sc.exe'), 'query wtfd', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

{ Running wtfd }

procedure Collect(const S: String; const Error, FirstLine: Boolean);
begin
  Output := Output + S + #13#10;
end;

{ SetPasswords puts the passwords where wtfd takes them from, in this
  process's environment, which the programs it runs inherit: never on their
  command line, which every user can see. Empty ones are none. }
procedure SetPasswords(Admin, DBA, API: String);
begin
  SetEnvironmentVariable('WTFD_ADMIN_DATABASE_PASSWORD', Admin);
  SetEnvironmentVariable('WTFD_DBA_DATABASE_PASSWORD', DBA);
  SetEnvironmentVariable('WTFD_API_DATABASE_PASSWORD', API);
end;

{ RunWtfd runs Filename with Params, without a window, and returns its exit
  code; Output has what it said. }
function RunWtfd(Filename, Params: String): Integer;
var
  Code: Integer;
begin
  Output := '';
  try
    if not ExecAndLogOutput(Filename, Params, '', SW_HIDE, ewWaitUntilTerminated, Code, @Collect) then
      Code := -1;
  except
    Output := GetExceptionMessage;
    Code := -1;
  end;
  Result := Code;
end;

function CheckProgram: String;
begin
  ExtractTemporaryFile('wtfd-check.exe');
  Result := ExpandConstant('{tmp}\wtfd-check.exe');
end;

function Flag(Name, Value: String): String;
begin
  Result := ' --' + Name + ' ' + AddQuotes(Value);
end;

function NewServerFlags: String;
begin
  Result := Flag('database-host', Trim(NewServerPage.Values[0])) +
    Flag('database-port', Trim(NewServerPage.Values[1])) +
    Flag('admin-user', Trim(NewServerPage.Values[2]));
end;

function DatabaseFlags: String;
begin
  if NewDatabase then
    Result := NewServerFlags +
      Flag('database-name', Trim(NewNamesPage.Values[0])) +
      Flag('dba-database-user', Trim(NewNamesPage.Values[1])) +
      Flag('api-database-user', Trim(NewNamesPage.Values[2]))
  else
    Result := Flag('database-host', Trim(ExistingServerPage.Values[0])) +
      Flag('database-port', Trim(ExistingServerPage.Values[1])) +
      Flag('database-name', Trim(ExistingServerPage.Values[2])) +
      Flag('dba-database-user', Trim(ExistingRolesPage.Values[0])) +
      Flag('api-database-user', Trim(ExistingRolesPage.Values[2]));
end;

procedure SetDatabasePasswords;
begin
  if NewDatabase then
    SetPasswords(NewServerPage.Values[3], '', '')
  else
    SetPasswords('', ExistingRolesPage.Values[1], ExistingRolesPage.Values[3]);
end;

{ Check runs wtfd database check, and says what is wrong, if anything. }
function Check(Params: String): Boolean;
begin
  WizardForm.NextButton.Enabled := False;
  try
    SetDatabasePasswords;
    Result := RunWtfd(CheckProgram, 'database check' + Params) = 0;
    SetPasswords('', '', '');
  finally
    WizardForm.NextButton.Enabled := True;
  end;
  if not Result then
    MsgBox(Trim(Output), mbError, MB_OK);
end;

{ The pages }

procedure BrowseFiles(Sender: TObject);
var
  Dir: String;
begin
  Dir := FilesEdit.Text;
  if BrowseForFolder('Where WtF keeps its files (photos and attachments):', Dir, True) then
    FilesEdit.Text := Dir;
end;

procedure CreateServerPage(After: Integer);
var
  Top: Integer;
  PortLabel, FilesLabel: TNewStaticText;
  Browse: TNewButton;
begin
  ServerPage := CreateCustomPage(After, 'The server',
    'Who can reach WtF, and where it keeps its files.');

  LocalRadio := TNewRadioButton.Create(ServerPage);
  LocalRadio.Parent := ServerPage.Surface;
  LocalRadio.Width := ServerPage.SurfaceWidth;
  LocalRadio.Caption := 'This computer only (a reverse proxy here passes requests on)';
  NetworkRadio := TNewRadioButton.Create(ServerPage);
  NetworkRadio.Parent := ServerPage.Surface;
  NetworkRadio.Top := LocalRadio.Top + LocalRadio.Height + ScaleY(6);
  NetworkRadio.Width := ServerPage.SurfaceWidth;
  NetworkRadio.Caption := 'Other computers on the network too';
  Top := NetworkRadio.Top + NetworkRadio.Height + ScaleY(16);

  PortLabel := TNewStaticText.Create(ServerPage);
  PortLabel.Parent := ServerPage.Surface;
  PortLabel.Top := Top;
  PortLabel.Caption := 'Port:';
  PortEdit := TNewEdit.Create(ServerPage);
  PortEdit.Parent := ServerPage.Surface;
  PortEdit.Top := PortLabel.Top + PortLabel.Height + ScaleY(4);
  PortEdit.Width := ScaleX(80);
  Top := PortEdit.Top + PortEdit.Height + ScaleY(16);

  FilesLabel := TNewStaticText.Create(ServerPage);
  FilesLabel.Parent := ServerPage.Surface;
  FilesLabel.Top := Top;
  FilesLabel.Caption := 'Files (photos and attachments), another drive if you like:';
  Browse := TNewButton.Create(ServerPage);
  Browse.Parent := ServerPage.Surface;
  Browse.Caption := 'Browse…';
  Browse.Width := ScaleX(80);
  Browse.Height := WizardForm.NextButton.Height;
  Browse.Top := FilesLabel.Top + FilesLabel.Height + ScaleY(4);
  Browse.Left := ServerPage.SurfaceWidth - Browse.Width;
  Browse.OnClick := @BrowseFiles;
  FilesEdit := TNewEdit.Create(ServerPage);
  FilesEdit.Parent := ServerPage.Surface;
  FilesEdit.Top := Browse.Top + (Browse.Height - FilesEdit.Height) div 2;
  FilesEdit.Width := Browse.Left - ScaleX(8);
end;

procedure InitializeWizard;
var
  Summary: String;
begin
  Upgrade := LoadStringsFromFile(ExpandConstant('{commonappdata}\WtF\wtfd.conf'), Settings);
  ServiceExisted := ServiceExists;

  Summary := '';
  if Upgrade then
    Summary := 'Database:  ' + Setting('database-name', 'wtf') + ' on ' +
      Setting('database-host', '127.0.0.1') + ':' + Setting('database-port', '5432') + #13#10 +
      'Roles:  ' + Setting('dba-database-user', 'wtf_dba') + ' and ' + Setting('api-database-user', 'wtf_api') + #13#10 +
      'Listens on:  ' + Setting('listen', '127.0.0.1:8080') + #13#10 +
      'Files:  ' + Setting('files-directory', ExpandConstant('{commonappdata}\WtF\files'));
  UpgradePage := CreateInputOptionPage(wpLicense, 'An upgrade',
    'WtF is set up on this computer already.',
    'Its settings are kept, and its database brought up to date:' + #13#10#13#10 + Summary,
    False, False);
  UpgradePage.Add('Change the settings');

  DatabasePage := CreateInputOptionPage(UpgradePage.ID, 'WtF''s database',
    'Is it on a PostgreSQL server already?',
    'WtF keeps everything in a PostgreSQL database, on this computer or another one, which needs PostgreSQL 18 or newer.',
    True, False);
  DatabasePage.Add('It is there already, with its two roles: connect to it');
  DatabasePage.Add('Make a new one, as an administrator of the PostgreSQL server');
  DatabasePage.Values[0] := Upgrade;
  DatabasePage.Values[1] := not Upgrade;

  NewServerPage := CreateInputQueryPage(DatabasePage.ID, 'The PostgreSQL server',
    'Where the new database goes, and an administrator there.',
    'The administrator (a superuser, or a role that may create roles and databases) makes the database and its roles. Its password is used only now, and isn''t kept.');
  NewServerPage.Add('Host:', False);
  NewServerPage.Add('Port:', False);
  NewServerPage.Add('Administrator:', False);
  NewServerPage.Add('Password:', True);
  NewServerPage.Values[0] := Setting('database-host', 'localhost');
  NewServerPage.Values[1] := Setting('database-port', '5432');
  NewServerPage.Values[2] := 'postgres';

  NewNamesPage := CreateInputQueryPage(NewServerPage.ID, 'The new database',
    'Its name, and the names of its two roles.',
    'The roles get passwords of their own, made up by wtfd, and kept in ' +
    ExpandConstant('{commonappdata}\WtF\pgpass.conf') + ', which only administrators can read.');
  NewNamesPage.Add('Database:', False);
  NewNamesPage.Add('Its owner (the DBA role):', False);
  NewNamesPage.Add('The role the server connects as (the API role):', False);
  NewNamesPage.Values[0] := 'wtf';
  NewNamesPage.Values[1] := 'wtf_dba';
  NewNamesPage.Values[2] := 'wtf_api';

  ExistingServerPage := CreateInputQueryPage(NewNamesPage.ID, 'The database',
    'Where it is.', '');
  ExistingServerPage.Add('Host:', False);
  ExistingServerPage.Add('Port:', False);
  ExistingServerPage.Add('Database:', False);
  ExistingServerPage.Values[0] := Setting('database-host', 'localhost');
  ExistingServerPage.Values[1] := Setting('database-port', '5432');
  ExistingServerPage.Values[2] := Setting('database-name', 'wtf');

  ExistingRolesPage := CreateInputQueryPage(ExistingServerPage.ID, 'The database''s roles',
    'Its owner, and the role the server connects as, with their passwords.',
    'The passwords are kept in ' + ExpandConstant('{commonappdata}\WtF\pgpass.conf') +
    ', which only administrators can read.');
  ExistingRolesPage.Add('Its owner (the DBA role):', False);
  ExistingRolesPage.Add('Its password:', True);
  ExistingRolesPage.Add('The role the server connects as (the API role):', False);
  ExistingRolesPage.Add('Its password:', True);
  ExistingRolesPage.Values[0] := Setting('dba-database-user', 'wtf_dba');
  ExistingRolesPage.Values[2] := Setting('api-database-user', 'wtf_api');
  if Upgrade then
    ExistingRolesPage.SubCaptionLabel.Caption := ExistingRolesPage.SubCaptionLabel.Caption +
      ' A password left empty is the one kept there already.';

  AccountPage := CreateInputQueryPage(ExistingRolesPage.ID, 'The first account',
    'WtF''s first administrator.',
    'Its password is made up, and shown at the end, once. More accounts are made in WtF itself.');
  AccountPage.Add('Email:', False);

  CreateServerPage(AccountPage.ID);
  NetworkRadio.Checked := Pos('127.0.0.1', Setting('listen', '127.0.0.1')) <> 1;
  LocalRadio.Checked := not NetworkRadio.Checked;
  PortEdit.Text := ListenPort(Setting('listen', '127.0.0.1:8080'));
  FilesEdit.Text := Setting('files-directory', ExpandConstant('{commonappdata}\WtF\files'));

  ServicePage := CreateInputOptionPage(ServerPage.ID, 'The service',
    'How WtF runs.', '', False, False);
  ServicePage.Add('Run WtF as a Windows service, from startup on');
  ServicePage.Add('Let other computers reach it through Windows Firewall');
  ServicePage.Values[0] := True;

  ResultPage := CreateOutputMsgMemoPage(wpInstalling, 'Finished', '', '', '');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = UpgradePage.ID then
    Result := not Upgrade
  else if (PageID = DatabasePage.ID) or (PageID = ServerPage.ID) then
    Result := KeepSettings
  else if (PageID = NewServerPage.ID) or (PageID = NewNamesPage.ID) then
    Result := KeepSettings or not NewDatabase
  else if (PageID = ExistingServerPage.ID) or (PageID = ExistingRolesPage.ID) then
    Result := KeepSettings or NewDatabase
  else if PageID = AccountPage.ID then
    Result := KeepSettings or (not NewDatabase and (Accounts > 0))
  else if PageID = ServicePage.ID then
    Result := KeepSettings and ServiceExisted;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = ServicePage.ID then
  begin
    { Ticked when it listens on the network, and only then of use. }
    ServicePage.Values[0] := ServicePage.Values[0] or ServiceExisted;
    ServicePage.Values[1] := NetworkRadio.Checked;
    ServicePage.CheckListBox.ItemEnabled[1] := NetworkRadio.Checked;
  end;
end;

function ValidPort(Port: String): Boolean;
var
  N: Integer;
begin
  N := StrToIntDef(Trim(Port), 0);
  Result := (N >= 1) and (N <= 65535);
  if not Result then
    MsgBox('The port is a number from 1 to 65535.', mbError, MB_OK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  P: Integer;
begin
  Result := True;
  if CurPageID = NewServerPage.ID then
    Result := ValidPort(NewServerPage.Values[1]) and
      Check(' --new --server-only' + NewServerFlags)
  else if CurPageID = NewNamesPage.ID then
    Result := Check(' --new' + DatabaseFlags)
  else if CurPageID = ExistingServerPage.ID then
    Result := ValidPort(ExistingServerPage.Values[1])
  else if CurPageID = ExistingRolesPage.ID then
  begin
    { An empty password is the one in pgpass.conf, on an upgrade. }
    SetEnvironmentVariable('PGPASSFILE', ExpandConstant('{commonappdata}\WtF\pgpass.conf'));
    Result := Check(DatabaseFlags);
    Accounts := 0;
    P := Pos('Accounts: ', Output);
    if Result and (P > 0) then
      Accounts := StrToIntDef(Trim(Copy(Output, P + 10, 10)), 0);
  end
  else if CurPageID = AccountPage.ID then
  begin
    Result := Pos('@', AccountPage.Values[0]) > 1;
    if not Result then
      MsgBox('Give the first account''s email address.', mbError, MB_OK);
  end
  else if CurPageID = ServerPage.ID then
  begin
    Result := ValidPort(PortEdit.Text);
    if Result and (Trim(FilesEdit.Text) = '') then
    begin
      MsgBox('Choose where WtF keeps its files.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := 'The programs:' + NewLine + Space + ExpandConstant('{app}\bin') + NewLine + NewLine;
  if KeepSettings then
  begin
    Result := Result + 'The settings:' + NewLine + Space + 'as they are, in ' +
      ExpandConstant('{commonappdata}\WtF\wtfd.conf') + NewLine + Space +
      'and the database brought up to date' + NewLine;
    if ServiceExisted then
      Result := Result + NewLine + 'The service:' + NewLine + Space + 'started again' + NewLine;
  end
  else
  begin
    if NewDatabase then
      Result := Result + 'A new database:' + NewLine + Space + Trim(NewNamesPage.Values[0]) + ' on ' +
        Trim(NewServerPage.Values[0]) + ':' + Trim(NewServerPage.Values[1]) + ', made by ' +
        Trim(NewServerPage.Values[2]) + NewLine + Space + 'with the roles ' +
        Trim(NewNamesPage.Values[1]) + ' and ' + Trim(NewNamesPage.Values[2]) + NewLine
    else
      Result := Result + 'The database:' + NewLine + Space + Trim(ExistingServerPage.Values[2]) + ' on ' +
        Trim(ExistingServerPage.Values[0]) + ':' + Trim(ExistingServerPage.Values[1]) + NewLine + Space +
        'with the roles ' + Trim(ExistingRolesPage.Values[0]) + ' and ' + Trim(ExistingRolesPage.Values[2]) + NewLine;
    if not ShouldSkipPage(AccountPage.ID) then
      Result := Result + NewLine + 'The first account:' + NewLine + Space + Trim(AccountPage.Values[0]) + NewLine;
    Result := Result + NewLine + 'The server:' + NewLine + Space + 'listens on ' + Listen + NewLine +
      Space + 'files in ' + Trim(FilesEdit.Text) + NewLine;
    if ServicePage.Values[0] then
    begin
      Result := Result + NewLine + 'The service:' + NewLine + Space + 'wtfd, from startup on' + NewLine;
      if NetworkRadio.Checked and ServicePage.Values[1] then
        Result := Result + Space + 'with a Windows Firewall rule for port ' + Trim(PortEdit.Text) + NewLine;
    end;
  end;
end;

{ Installing }

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  { The running service holds wtfd.exe, which can't be replaced then. }
  if ServiceExisted then
    Exec(ExpandConstant('{sys}\net.exe'), 'stop wtfd', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

{ Step runs one of wtfd's steps, adding what it said to the log. }
function Step(Status, Params: String): Boolean;
begin
  WizardForm.StatusLabel.Caption := Status;
  Result := RunWtfd(ExpandConstant('{app}\bin\wtfd.exe'), Params) = 0;
  StepLog := StepLog + '> wtfd ' + Params + #13#10 + Output + #13#10;
  if not Result then
    Failed := True;
end;

{ FindPassword finds the first account's password in what wtfd said: the
  line "Account … created, an admin, with password … (shown only this once …)". }
procedure FindPassword;
var
  P: Integer;
  Rest: String;
begin
  P := Pos('with password ', Output);
  if P > 0 then
  begin
    Rest := Copy(Output, P + 14, Length(Output));
    P := Pos(' ', Rest);
    if P > 0 then
      AccountPassword := Copy(Rest, 1, P - 1);
  end;
end;

procedure Install;
var
  Params: String;
  Service: Boolean;
begin
  Params := 'install';
  if not KeepSettings then
  begin
    if NewDatabase then
      Params := Params + ' --database new'
    else
      Params := Params + ' --database existing';
    Params := Params + DatabaseFlags + Flag('listen', Listen) + Flag('files-directory', Trim(FilesEdit.Text));
    if not ShouldSkipPage(AccountPage.ID) then
      Params := Params + Flag('first-account', Trim(AccountPage.Values[0]));
    SetDatabasePasswords;
  end;
  Step('Setting WtF up, and its database…', Params);
  SetPasswords('', '', '');
  { The passwords aren't in the log. }
  FindPassword;
  if AccountPassword <> '' then
    StringChangeEx(StepLog, AccountPassword, '(shown above)', True);
  if Failed then
    Exit;

  Service := ServicePage.Values[0] or ServiceExisted;
  if not ShouldSkipPage(ServicePage.ID) then
    Service := ServicePage.Values[0];
  if Service then
  begin
    Params := 'service install';
    { Without the page, a rule that is there stays as it is. }
    if not ShouldSkipPage(ServicePage.ID) then
    begin
      if NetworkRadio.Checked and ServicePage.Values[1] then
        Params := Params + ' --firewall yes'
      else
        Params := Params + ' --firewall no';
    end;
    Step('Setting up the service, and starting it…', Params);
  end
  else if ServiceExisted then
    Step('Removing the service…', 'service uninstall');
end;

function Address: String;
var
  Host: String;
begin
  Host := '127.0.0.1';
  if KeepSettings then
  begin
    if Pos('127.0.0.1', Setting('listen', '127.0.0.1')) <> 1 then
      Host := GetComputerNameString;
    Result := 'http://' + Host + ':' + ListenPort(Setting('listen', '127.0.0.1:8080'));
  end
  else
  begin
    if NetworkRadio.Checked then
      Host := GetComputerNameString;
    Result := 'http://' + Host + ':' + Trim(PortEdit.Text);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Text: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  Install;
  if Failed then
  begin
    ResultPage.Caption := 'Something went wrong';
    ResultPage.Description := 'The programs are installed, but WtF isn''t set up.';
    Text := 'Once the cause is put right, run this setup again: it goes on from where it stopped.' + #13#10#13#10;
  end
  else
  begin
    ResultPage.Caption := 'WtF is installed';
    ResultPage.Description := 'Open ' + Address + ' in a browser, or the apps, to log in.';
    Text := '';
    if AccountPassword <> '' then
      Text := 'The first account:' + #13#10 + '  Email: ' + Trim(AccountPage.Values[0]) + #13#10 +
        '  Password: ' + AccountPassword + #13#10#13#10 +
        'Note the password now: it is shown only this once. Change it after logging in.' + #13#10#13#10;
    Text := Text + 'The server: ' + Address + #13#10#13#10 + 'What was done:' + #13#10#13#10;
  end;
  ResultPage.RichEditViewer.Text := Text + StepLog;
end;

{ Uninstalling }

{ RemoveFromPath takes the programs' folder, which wtfd install added, off
  the machine's PATH. }
procedure RemoveFromPath(Dir: String);
var
  Path, Rest, Entry, Kept: String;
  P: Integer;
begin
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', Path) then
    Exit;
  Rest := Path;
  Kept := '';
  while Rest <> '' do
  begin
    P := Pos(';', Rest);
    if P = 0 then
    begin
      Entry := Rest;
      Rest := '';
    end
    else
    begin
      Entry := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, Length(Rest));
    end;
    if (Entry <> '') and (CompareText(RemoveBackslashUnlessRoot(Trim(Entry)), RemoveBackslashUnlessRoot(Dir)) <> 0) then
    begin
      if Kept <> '' then
        Kept := Kept + ';';
      Kept := Kept + Entry;
    end;
  end;
  if Kept <> Path then
    RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', Kept);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  RemoveFromPath(ExpandConstant('{app}\bin'));
  if not UninstallSilent then
    MsgBox('The programs and the service are removed. WtF''s data stays: the settings, the passwords and the files in ' +
      ExpandConstant('{commonappdata}\WtF') + ', and the database. Delete them yourself if they are no longer wanted.',
      mbInformation, MB_OK);
end;
