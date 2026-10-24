unit CyrusAddonDeploy;

{ ---------------------------------------------------------------------------
  ADDON DEPLOY TARGET TOGGLE  --  read this before building a release.

  The companion addon (OrganizeItemsThroughBagSyncExport) is embedded in the
  .exe (see addon.res) and written to disk once at startup, and only when a
  target file is missing or its bytes differ - a normal run writes nothing
  (idempotent; see DeployOne / DeployCompanionAddon below).

  WHERE it deploys is decided by the ADDON_DEPLOY_TEST symbol on the last line
  of this block, through StartupAddonDir():

    DEFINED = TEST MODE (the current state):
      -> <folder of the .exe>\_addon_deploy_test\OrganizeItemsThroughBagSyncExport\
      A harmless local folder beside the program. Use it while developing on a
      machine with no WoW installed (like this one): the deploy logic runs and
      can be verified, yet nothing touches a real game install.

    NOT defined = RELEASE MODE:
      -> <WoW>\_retail_\Interface\AddOns\OrganizeItemsThroughBagSyncExport\
      The real AddOns folder, derived at run time from the detected BagSync.lua
      path - AddonDirFromAnyRetailPath() locates the \_retail_\ segment in that path and
      rebuilds <...>\_retail_\Interface\AddOns\<addon>. If BagSync.lua has not
      been located yet, StartupAddonDir() returns '' and the deploy is simply
      skipped (it retries on a later run, once the path is known).

  TO SHIP A RELEASE:
    1. Disable the compiler directive on the LAST LINE of this comment block.
       It is the ADDON_DEPLOY_TEST define (open-brace, dollar, DEFINE, name,
       close-brace). Put a dot right after the opening brace - open-brace, DOT,
       dollar, DEFINE ADDON_DEPLOY_TEST, close-brace - which makes it an inert
       comment; or simply delete that whole line.
    2. Rebuild. IsAddonDeployTestMode is then False, and the Main-tab log reads
       'Checking the bundled companion addon in your WoW AddOns folder' instead
       of '[TEST MODE] ...'. That log line is the quickest way to confirm mode.
    3. If any of the 3 addon files (.toc, .lua, IDs.lua) or about.txt changed,
       first recompile the resource:  brcc32 addon.rc   (regenerates addon.res),
       otherwise the .exe still embeds the old copies.

  ELEVATION CAVEAT (release only): if WoW sits under a protected location such
  as C:\Program Files (x86)\..., writing into its AddOns folder needs admin
  rights. DeployCompanionAddon never raises - it reports the failure to the log
  - so a blocked write cannot crash the app; but the addon will not appear until
  the program is run elevated, or WoW lives in a user-writable folder.
  --------------------------------------------------------------------------- }
{$DEFINE ADDON_DEPLOY_TEST}

{ ============================================================================
  Embeds the companion addon (OrganizeItemsThroughBagSyncExport) and the About
  text inside the executable, and deploys the addon into the WoW AddOns folder.

  The three addon files and the About text are linked in from addon.res
  (compiled from addon.rc). Nothing here is written to disk unless a target
  file is missing or differs from the embedded copy (idempotent).
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes;

const
  ADDON_FOLDER_NAME = 'OrganizeItemsThroughBagSyncExport';

/// <summary>Help/intro text shown in the Main tab, loaded from the resource.</summary>
function GetAboutText: string;

/// <summary>Standard AddOns folder for the companion addon under a WoW root.</summary>
function CompanionAddonDir(const AWoWRoot: string): string;

/// <summary>
/// Writes the embedded addon files into AAddonDir, but only the ones that are
/// missing or differ from the embedded copy. Returns how many files were
/// written; logs each action to ALog when provided. Never raises - any failure
/// (e.g. a read-only Program Files install) is reported via ALog and AError.
/// </summary>
function DeployCompanionAddon(const AAddonDir: string; ALog: TStrings;
  out AError: string): Integer;

/// <summary>From any path that contains a "_retail_" component, returns the
/// companion addon folder ...\_retail_\Interface\AddOns\&lt;addon&gt;, or '' when
/// no "_retail_" component is present.</summary>
function AddonDirFromAnyRetailPath(const APath: string): string;

/// <summary>The deploy target used at startup. In a test build
/// (ADDON_DEPLOY_TEST defined) this is a local folder beside the .exe; in a
/// release build it is derived from the given BagSync.lua path. Returns '' when
/// it cannot be determined.</summary>
function StartupAddonDir(const ABagSyncLuaPath: string): string;

/// <summary>True when built in addon-deploy test mode.</summary>
function IsAddonDeployTestMode: Boolean;

implementation

uses
  Winapi.Windows, System.IOUtils;

{$R addon.res}

function ResourceBytes(const AResName: string): TBytes;
var
  rs: TResourceStream;
begin
  rs := TResourceStream.Create(HInstance, AResName, RT_RCDATA);
  try
    SetLength(Result, rs.Size);
    if rs.Size > 0 then
      rs.ReadBuffer(Result[0], rs.Size);
  finally
    rs.Free;
  end;
end;

function GetAboutText: string;
var
  rs: TResourceStream;
  sl: TStringList;
begin
  Result := '';
  try
    rs := TResourceStream.Create(HInstance, 'ABOUT_TEXT', RT_RCDATA);
    try
      sl := TStringList.Create;
      try
        sl.LoadFromStream(rs, TEncoding.UTF8);
        Result := sl.Text;
      finally
        sl.Free;
      end;
    finally
      rs.Free;
    end;
  except
    on E: Exception do
      Result := 'OrganizeEntropy - a World of Warcraft inventory consolidation helper.';
  end;
end;

function CompanionAddonDir(const AWoWRoot: string): string;
begin
  Result := TPath.Combine(AWoWRoot,
    '_retail_\Interface\AddOns\' + ADDON_FOLDER_NAME);
end;

function AddonDirFromAnyRetailPath(const APath: string): string;
const
  MARK = '\_retail_\';   // 10 chars: \ _ r e t a i l _ \
var
  p: Integer;
  retailRoot: string;
begin
  Result := '';
  if APath = '' then
    Exit;
  // WoW's "_retail_" folder is always lower case; compare case-insensitively.
  p := Pos(MARK, LowerCase(APath));
  if p = 0 then
    Exit;
  // Everything up to and including "_retail_" (excluding the trailing '\').
  retailRoot := Copy(APath, 1, p + Length(MARK) - 2);
  Result := TPath.Combine(retailRoot, 'Interface\AddOns\' + ADDON_FOLDER_NAME);
end;

function IsAddonDeployTestMode: Boolean;
begin
  {$IFDEF ADDON_DEPLOY_TEST}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function StartupAddonDir(const ABagSyncLuaPath: string): string;
begin
  {$IFDEF ADDON_DEPLOY_TEST}
  // TEST: a local folder beside the .exe - safe on a machine without WoW.
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)),
    '_addon_deploy_test\' + ADDON_FOLDER_NAME);
  {$ELSE}
  // RELEASE: the real WoW AddOns folder, derived from the BagSync.lua path.
  Result := AddonDirFromAnyRetailPath(ABagSyncLuaPath);
  {$ENDIF}
end;

function BytesEqual(const A, B: TBytes): Boolean;
var
  i: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for i := 0 to High(A) do
    if A[i] <> B[i] then
      Exit(False);
  Result := True;
end;

// Returns True if it actually wrote the file (missing or different).
function DeployOne(const AResName, ADestFile: string): Boolean;
var
  data: TBytes;
begin
  data := ResourceBytes(AResName);
  if TFile.Exists(ADestFile) and BytesEqual(TFile.ReadAllBytes(ADestFile), data) then
    Exit(False);
  TFile.WriteAllBytes(ADestFile, data);
  Result := True;
end;

function DeployCompanionAddon(const AAddonDir: string; ALog: TStrings;
  out AError: string): Integer;

  procedure Note(const S: string);
  begin
    if Assigned(ALog) then
      ALog.Add(S);
  end;

type
  TPair = record ResName, FileName: string; end;
const
  Files: array[0..2] of TPair = (
    (ResName: 'ADDON_TOC'; FileName: ADDON_FOLDER_NAME + '.toc'),
    (ResName: 'ADDON_LUA'; FileName: ADDON_FOLDER_NAME + '.lua'),
    (ResName: 'ADDON_IDS'; FileName: 'OrganizeItemsThroughBagSyncIDs.lua'));
var
  i, written: Integer;
  dest: string;
begin
  AError := '';
  written := 0;
  try
    if not TDirectory.Exists(AAddonDir) then
      TDirectory.CreateDirectory(AAddonDir);
    for i := Low(Files) to High(Files) do
    begin
      dest := TPath.Combine(AAddonDir, Files[i].FileName);
      if DeployOne(Files[i].ResName, dest) then
      begin
        Inc(written);
        Note('Deployed: ' + Files[i].FileName);
      end;
    end;
    if written = 0 then
      Note('Companion addon already up to date.')
    else
      Note(Format('Companion addon deployed (%d file(s) written) to:', [written]));
    if written > 0 then
      Note('  ' + AAddonDir);
  except
    on E: Exception do
    begin
      AError := E.Message;
      Note('Could not deploy companion addon: ' + E.Message);
    end;
  end;
  Result := written;
end;

end.
