unit MainFrm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, System.IniFiles, System.StrUtils, System.DateUtils,
  Vcl.ExtCtrls, Vcl.Grids, Vcl.ComCtrls, Vcl.Clipbrd,
  System.Generics.Collections, System.Generics.Defaults, System.Types,
  System.Threading, System.Math, System.IOUtils, WoWPathDetector,
  Data.DB, FireDAC.Comp.Client,
  CyrusParser, CyrusDB, System.Hash, System.UITypes, CyrusAddonImporter,
  CyrusConsolidator, CyrusAddonDeploy;

type
  TfrmMain = class(TForm)
    PageControl1: TPageControl;
    TabSheet1: TTabSheet;
    TabSheet2: TTabSheet;
    Panel1: TPanel;
    Label1: TLabel;
    Edit1: TEdit;
    btnLocate: TButton;
    btnExecute: TButton;
    FlowPanelGuilds: TFlowPanel;
    memoInfo: TMemo;
    StringGrid1: TStringGrid;
    btnImportItems: TButton;
    procedure FormCreate(Sender: TObject);
    procedure btnLocateClick(Sender: TObject);
    procedure btnExecuteClick(Sender: TObject);
//    procedure FormResize(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnImportItemsClick(Sender: TObject);


  private
    FDatabase: TCyrusDB;
    FConsolidator: TCyrusConsolidator;
    FOwnerChecks: TList<TCheckBox>;
    FLastResults: TList<TConsolidationResult>;
    FBusy: Boolean;
    FLoadingFilter: Boolean;

    // Dynamically-created controls (Milestones B/C/D/E) - kept in code so the
    // changeset stays portable and does not depend on .dfm edits.
    FlowPanelChars: TFlowPanel;
    lblCharsHdr, lblGuildsHdr: TLabel;
    btnSelAllChars, btnSelNoneChars: TButton;
    btnSelAllGuilds, btnSelNoneGuilds: TButton;
    btnConsolidate: TButton;
    lblScope: TLabel;
    pnlDetail: TPanel;
    memoMoves: TMemo;
    btnCopyMoves: TButton;
    prog: TProgressBar;
    lblFileDate: TLabel;
    splitterConso: TSplitter;
    FChainImport: Boolean;
    FStartupDeployDone: Boolean;
    FStartupPathResolved: Boolean;  // async WoW detection finished -> addon deploy may run
    FSortCol: Integer;      // active sort column (-1 = default order)
    FSortState: Integer;    // 0 = default, 1 = ascending, 2 = descending
    FHdrDownCol: Integer;   // header column the mouse went down on (-1 = none)
    FHdrDownX: Integer;     // mouse-down X, to tell a click from a column-resize drag

    function HasValidBagSyncPath: Boolean;
    procedure LoadFromIni;
    function PromptForBagSyncFile: Boolean;
    procedure UpdateUIAfterLoad(Success: Boolean);
    procedure CopyBagSyncToLocal;
    function GetLocalBagSyncPath: string;
    function GetFileLastModifiedDateTime(const FileName: string): TDateTime;
    procedure ExecuteParsing;
    procedure ClearGuilds;
    procedure AddGuildCheckbox(const GuildName: string; Count: Integer);
    function ResolveRetailWoWAccountPathTakeTwo(const WoWRoot: string): string;
    function ResolveAddonExportPath: string;
    procedure ExecuteAddonImport;

    // --- Milestone B: participation filter ---
    procedure BuildDynamicUI;
    procedure PopulateOwnerFilters;
    procedure OwnerCheckboxClick(Sender: TObject);
    function  GetSelectedOwnerIDs: TArray<Integer>;
    procedure SaveOwnerFilterToIni;
    procedure LoadOwnerFilterFromIni;
    procedure UpdateScopeLabel;
    procedure SetOwnersChecked(AParent: TWinControl; AValue: Boolean);
    procedure btnSelAllCharsClick(Sender: TObject);
    procedure btnSelNoneCharsClick(Sender: TObject);
    procedure btnSelAllGuildsClick(Sender: TObject);
    procedure btnSelNoneGuildsClick(Sender: TObject);

    // --- Milestone C: consolidation engine ---
    procedure btnConsolidateClick(Sender: TObject);
    procedure RunConsolidationUI;
    procedure PopulateResultsGrid;
    procedure StringGrid1SelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
    procedure StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect; State: TGridDrawState);
    procedure StringGrid1MouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure StringGrid1MouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure CycleSortColumn(ACol: Integer);
    procedure ApplyResultSort;

    // --- Milestone D: move suggestions ---
    procedure ShowMoveDetailForRow(RowIndex: Integer);
    function  BuildMoveInstructions(const R: TConsolidationResult; ALocs: TList<TItemLocation>): TStringList;
    function  StorageMoveNote(const AStorage: string; AsDestination: Boolean): string;
    function  LocDesc(const ALoc: TItemLocation): string;
    procedure btnCopyMovesClick(Sender: TObject);
    function  QualityToColor(AQuality: Integer): TColor;
    function  BindTypeToStr(ABind: Integer): string;

    // --- Milestone E: async parse + polish ---
    procedure Log(const S: string);
    procedure SetBusy(ABusy: Boolean);
    procedure RunBagSyncAsync;
    procedure OnBagSyncDone(ASuccess: Boolean; const AError: string);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    function  CheckAddonTocVersion(const AAddonLuaPath: string): string;
    function  BindLabel(const R: TConsolidationResult): string;
    function  BagSyncFileWarning: string;
    procedure DebugLog(const S: string);
    procedure FormActivate(Sender: TObject);
    procedure DeployAddonOnStartup;
    procedure StartWoWDetection;                      // slow WoW drive scan, off-thread
    procedure OnWoWDetected(const AWoWRoot: string);  // main-thread completion of the scan
    procedure TryStartupDeploy;                       // deploy addon once, after path known
    function  OwnerIniKey(const S: string): string;
  public
    { Public declarations }
  end;

var
  frmMain: TfrmMain;

const
  INI_FILENAME = 'OrganizeItemsThroughBagSync.ini';
  INI_SECTION  = 'Settings';
  INI_KEY      = 'BagSyncPath';
  INI_KEY_ADDON_PATH = 'AddonExportPath';

implementation

{$R *.dfm}

var
  // Guards the async WoW-detection callback: set False in FormDestroy so a queued
  // completion cannot touch a form being torn down. Safe as a unit var because both
  // the callback and FormDestroy run on the main thread.
  UDetectAlive: Boolean = False;

function GetIniPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + INI_FILENAME;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  Edit1.ReadOnly := True;
  Edit1.Color    := clBtnFace;

  PageControl1.ActivePageIndex := 0;

  memoInfo.ReadOnly   := True;
  memoInfo.ScrollBars := ssVertical;

  // Help / intro text is embedded (addon.res -> ABOUT_TEXT) and loaded here,
  // instead of dozens of inline Lines.Add calls. Edit about.txt to change it.
  memoInfo.Lines.Text := GetAboutText;

  // --- Initialize database (mandatory; halt on failure) ---
  FDatabase := TCyrusDB.Create;
  try
    FDatabase.InitializeDatabase;
  except
    on E: Exception do
    begin
      Application.ShowException(E);
      Halt;
    end;
  end;

  // --- Milestones B-E wiring ---
  FConsolidator := TCyrusConsolidator.Create(FDatabase.Connection);
  FOwnerChecks  := TList<TCheckBox>.Create;
  FLastResults  := TList<TConsolidationResult>.Create;

  BuildDynamicUI;
  OnCloseQuery := FormCloseQuery;
  OnActivate := FormActivate;

  PopulateOwnerFilters;

  Constraints.MinWidth  := 700;
  Constraints.MinHeight := 550;
  Position := poScreenCenter;

  // --- Auto-detect WoW install / BagSync.lua path ASYNCHRONOUSLY ---
  // The detector may recursively scan every fixed drive (slow when WoW is not in
  // a default location), so it runs on a worker thread and the window appears at
  // once; OnWoWDetected finishes the work back on the main thread.
  Edit1.Text         := '';
  Label1.Caption     := 'Detecting your WoW installation, please wait...';
  Label1.Font.Color  := clGrayText;
  Label1.Font.Style  := [fsBold];
  btnExecute.Enabled := False;
  Screen.Cursor      := crAppStart;   // arrow + hourglass; the window stays usable
  StartWoWDetection;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  UDetectAlive := False;   // stop any queued WoW-detection callback touching a freed form
  if Assigned(FOwnerChecks) then
    SaveOwnerFilterToIni;
  FLastResults.Free;
  FOwnerChecks.Free;
  FConsolidator.Free;
  FDatabase.Free;
end;

//procedure TfrmMain.FormResize(Sender: TObject);
//begin
//  ClientWidth  := 925;
//  ClientHeight := 750;
//end;

// ---------------------------------------------------------------------------
// INI / path helpers
// ---------------------------------------------------------------------------

procedure TfrmMain.LoadFromIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(GetIniPath);
  try
    Edit1.Text := Ini.ReadString(INI_SECTION, INI_KEY, '');
  finally
    Ini.Free;
  end;
end;

function TfrmMain.HasValidBagSyncPath: Boolean;
begin
  Result :=
    (Edit1.Text <> '') and
    FileExists(Edit1.Text) and
    SameText(ExtractFileName(Edit1.Text), 'BagSync.lua');
end;

function TfrmMain.GetLocalBagSyncPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'BagSync.lua';
end;

function TfrmMain.GetFileLastModifiedDateTime(const FileName: string): TDateTime;
var
  Age: Integer;
begin
  Result := 0;
  Age    := FileAge(FileName);
  if Age <> -1 then
    Result := FileDateToDateTime(Age);
end;

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

procedure TfrmMain.UpdateUIAfterLoad(Success: Boolean);
begin
  if Success then
  begin
    Label1.Caption    := 'BagSync.lua is READY - no need to re-locate. Just click "Do the magic!".';
    Label1.Font.Color := clGreen;
    Label1.Font.Style := [fsBold];
    btnLocate.Caption := 'Re-locate / Change / Update';
  end
  else
  begin
    Label1.Caption    := 'BagSync.lua not set - click "Locate BagSync.lua".';
    Label1.Font.Color := clRed;
    Label1.Font.Style := [fsBold];
    btnLocate.Caption := 'Locate BagSync.lua';
  end;
  btnExecute.Enabled := Success and (not FBusy);
  if Assigned(lblFileDate) then
  begin
    lblFileDate.Caption := BagSyncFileWarning;
    if Pos('OLD', lblFileDate.Caption) > 0 then
      lblFileDate.Font.Color := clMaroon
    else
      lblFileDate.Font.Color := clGrayText;
  end;
end;

procedure TfrmMain.AddGuildCheckbox(const GuildName: string; Count: Integer);
var
  cb: TCheckBox;
begin
  cb := TCheckBox.Create(Self);
  cb.Parent  := FlowPanelGuilds;
  cb.Caption := Format('%s [%d]', [GuildName, Count]);
  cb.Width   := 250;
  cb.Tag     := Count;
end;

procedure TfrmMain.ClearGuilds;
begin
  while FlowPanelGuilds.ControlCount > 0 do
    FlowPanelGuilds.Controls[0].Free;
end;

// ---------------------------------------------------------------------------
// File picker
// ---------------------------------------------------------------------------

function TfrmMain.PromptForBagSyncFile: Boolean;
var
  OpenDlg: TOpenDialog;
  Ini:     TIniFile;
  Chosen:  string;
begin
  Result := False;

  OpenDlg := TOpenDialog.Create(nil);
  try
    OpenDlg.Title       := 'Select BagSync.lua (SavedVariables folder)';
    OpenDlg.Filter      := 'BagSync.lua|BagSync.lua|Lua files (*.lua)|*.lua|All files (*.*)|*.*';
    OpenDlg.FilterIndex := 1;
    OpenDlg.Options     := [ofFileMustExist, ofPathMustExist, ofEnableSizing];

    if HasValidBagSyncPath then
    begin
      OpenDlg.InitialDir := ExtractFilePath(Edit1.Text);
      if not DirectoryExists(OpenDlg.InitialDir) then
        OpenDlg.InitialDir := '';
    end;

    if (OpenDlg.InitialDir = '') or not DirectoryExists(OpenDlg.InitialDir) then
    begin
      if DirectoryExists('C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account') then
        OpenDlg.InitialDir := 'C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account'
      else if DirectoryExists('C:\Program Files\World of Warcraft\_retail_\WTF\Account') then
        OpenDlg.InitialDir := 'C:\Program Files\World of Warcraft\_retail_\WTF\Account'
      else
        OpenDlg.InitialDir := 'C:\';
    end;

    if OpenDlg.Execute then
    begin
      Chosen := OpenDlg.FileName;
      if not SameText(ExtractFileName(Chosen), 'BagSync.lua') then
      begin
        memoInfo.Lines.Add('');
        memoInfo.Lines.Add('Error: you must select the file named "BagSync.lua".');
        memoInfo.Lines.Add('It is usually in:');
        memoInfo.Lines.Add('  ...\World of Warcraft\_retail_\WTF\Account\YourAccountName\SavedVariables\BagSync.lua');
        btnExecute.Enabled := False;
        UpdateUIAfterLoad(False);
        Exit;
      end;

      Ini := TIniFile.Create(GetIniPath);
      try
        Ini.WriteString(INI_SECTION, INI_KEY, Chosen);
      finally
        Ini.Free;
      end;

      Edit1.Text := Chosen;
      Result     := True;
    end;
  finally
    OpenDlg.Free;
  end;
end;

function TfrmMain.ResolveAddonExportPath: string;
// The addon export lives in the same SavedVariables folder as BagSync.lua
// Path: <WoWRoot>\_retail_\WTF\Account\<AccountName>\SavedVariables\
//       OrganizeItemsThroughBagSyncExport.lua
const
  ADDON_FILENAME = 'OrganizeItemsThroughBagSyncExport.lua';
var
  BagSyncDir : string;
  Candidate  : string;
begin
  Result := '';

  // Derive from the known BagSync.lua path
  if HasValidBagSyncPath then
  begin
    BagSyncDir := TPath.GetDirectoryName(Edit1.Text);
    Candidate  := TPath.Combine(BagSyncDir, ADDON_FILENAME);
    if TFile.Exists(Candidate) then
    begin
      Result := Candidate;
      Exit;
    end;
  end;

  // Fallback: check INI
  with TIniFile.Create(TPath.Combine(
         TPath.GetDirectoryName(ParamStr(0)), INI_FILENAME)) do
  try
    Result := ReadString(INI_SECTION, INI_KEY_ADDON_PATH, '');
  finally
    Free;
  end;
end;

// ---------------------------------------------------------------------------
// WoW account path resolution
// ---------------------------------------------------------------------------

function TfrmMain.ResolveRetailWoWAccountPathTakeTwo(const WoWRoot: string): string;
var
  AccountBase:   string;
  AllFolders:    TArray<string>;
  ValidAccounts: TStringList;
  TaskDlg:       TTaskDialog;
  I:             Integer;
  FolderName:    string;
begin
  Result      := '';
  AccountBase := TPath.Combine(WoWRoot, '_retail_\WTF\Account');

  if not TDirectory.Exists(AccountBase) then
    Exit;

  AllFolders    := TDirectory.GetDirectories(AccountBase);
  ValidAccounts := TStringList.Create;
  try
    for I := 0 to High(AllFolders) do
    begin
      FolderName := TPath.GetFileName(AllFolders[I]);
      if not SameText(FolderName, 'SavedVariables') then
        ValidAccounts.Add(AllFolders[I]);
    end;

    if ValidAccounts.Count = 0 then
      Exit;

    TaskDlg := TTaskDialog.Create(nil);
    try
      TaskDlg.Caption       := 'WoW Account Selection';
      TaskDlg.CommonButtons := [tcbOk, tcbCancel];

      if ValidAccounts.Count > 1 then
      begin
        TaskDlg.Title := 'Multiple WoW accounts detected.';
        TaskDlg.Text  := 'Please select the account you wish to sync:';

        for I := 0 to ValidAccounts.Count - 1 do
        begin
          with TaskDlg.RadioButtons.Add do
          begin
            Caption := TPath.GetFileName(ValidAccounts[I]);
            if I = 0 then Default := True;
          end;
        end;

        if TaskDlg.Execute then
          if Assigned(TaskDlg.RadioButton) then
            Result := ValidAccounts[TaskDlg.RadioButton.Index];
      end
      else
      begin
        FolderName    := TPath.GetFileName(ValidAccounts[0]);
        TaskDlg.Title := 'Confirm WoW Account';
        TaskDlg.Text  := Format('Found account folder: "%s".'#13#10'Is this correct?', [FolderName]);

        if TaskDlg.Execute then
          Result := ValidAccounts[0];
      end;

    finally
      TaskDlg.Free;
    end;
  finally
    ValidAccounts.Free;
  end;
end;

// ---------------------------------------------------------------------------
// BagSync.lua local copy
// ---------------------------------------------------------------------------

procedure TfrmMain.CopyBagSyncToLocal;
var
  Source, Dest: string;
  dt: TDateTime;
begin
  if not HasValidBagSyncPath then
  begin
    memoInfo.Lines.Add('Error: no valid BagSync.lua source path.');
    Exit;
  end;

  Source := Edit1.Text;
  Dest   := GetLocalBagSyncPath;

  if FileExists(Dest) then
    DeleteFile(Dest);

  if CopyFile(PChar(Source), PChar(Dest), False) then
  begin
    memoInfo.Lines.Add('BagSync.lua copied OK.');
    try
      dt := GetFileLastModifiedDateTime(Dest);
      if dt > 0 then
        memoInfo.Lines.Add('Last saved: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', dt));
    except
      memoInfo.Lines.Add('(could not read file timestamp)');
    end;
  end
  else
    memoInfo.Lines.Add('Copy failed: ' + SysErrorMessage(GetLastError));
end;

// ---------------------------------------------------------------------------
// Button handlers
// ---------------------------------------------------------------------------

procedure TfrmMain.btnLocateClick(Sender: TObject);
begin
  if PromptForBagSyncFile then
    UpdateUIAfterLoad(True)
  else
    if Edit1.Text = '' then
      UpdateUIAfterLoad(False);
end;

procedure TfrmMain.btnExecuteClick(Sender: TObject);
begin
  // One button does it all: synchronise the inventory, then import item metadata.
  FChainImport := True;
  DebugLog('btnExecute: begin sync + import');
  RunBagSyncAsync;
end;



procedure TfrmMain.btnImportItemsClick(Sender: TObject);
begin
  ExecuteAddonImport;
end;

procedure TfrmMain.ExecuteAddonImport;
var
  AddonPath   : string;
  FileContent : string;
  Importer    : TCyrusAddonImporter;
  ItemCount   : Integer;
begin
  AddonPath := ResolveAddonExportPath;

  // If auto-detect failed, prompt user
  if not TFile.Exists(AddonPath) then
  begin
    with TOpenDialog.Create(Self) do
    try
      Title  := 'Locate OrganizeItemsThroughBagSyncExport.lua';
      Filter := 'OrganizeItemsThroughBagSyncExport.lua|' +
                'OrganizeItemsThroughBagSyncExport.lua|' +
                'Lua files (*.lua)|*.lua';
      if Execute then
        AddonPath := FileName
      else
        Exit;
    finally
      Free;
    end;
  end;

  // Persist path
  with TIniFile.Create(TPath.Combine(
         TPath.GetDirectoryName(ParamStr(0)), INI_FILENAME)) do
  try
    WriteString(INI_SECTION, INI_KEY_ADDON_PATH, AddonPath);
  finally
    Free;
  end;

  memoInfo.Lines.Add('--- Addon Item Import ---');
  memoInfo.Lines.Add('File: ' + AddonPath);
  memoInfo.Lines.Add(CheckAddonTocVersion(AddonPath));

  FileContent := TFile.ReadAllText(AddonPath, TEncoding.UTF8);
  Importer    := TCyrusAddonImporter.Create(FileContent);
  ItemCount   := 0;

  try
    FDatabase.RebuildItemsStart; // Begin transaction (see below)
    try
      Importer.Execute(
        procedure(const Item: TAddonItem)
        begin
          FDatabase.UpsertItem(
            Item.ItemID,
            Item.Name,
            Item.Quality,
            Item.ItemLevel,
            Item.MinLevel,
            Item.ItemType,
            Item.ItemSubType,
            Item.MaxStack,
            Item.EquipLoc,
            Item.ClassID,
            Item.SubClassID,
            Item.BindType,
            Item.BindCategory,
            Item.TooltipBonding,
            Item.ExpacID,
            Item.SetID,
            Item.IsCraftingReagent,
            Item.ExportedAt
          );
          Inc(ItemCount);
        end
      );
      FDatabase.RebuildItemsCommit;
    except
      on E: Exception do
      begin
        FDatabase.RebuildItemsRollback;
        memoInfo.Lines.Add('ERROR during item import: ' + E.Message);
        raise;
      end;
    end;
  finally
    memoInfo.Lines.Add(Format('Items imported : %d', [ItemCount]));
    memoInfo.Lines.Add(Format('Items skipped  : %d', [Importer.Skipped]));
    memoInfo.Lines.Add('Item import complete.');

    Importer.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Core parse + DB import
// ---------------------------------------------------------------------------

procedure TfrmMain.ExecuteParsing;
var
  InputFile:   string;
  FileContent: string;
  Engine:      TCyrusEngine;
  FS:          TFileStream;
begin
  InputFile := GetLocalBagSyncPath;

  if not FileExists(InputFile) then
  begin
    Log('Local BagSync.lua not found.');
    Exit;
  end;

  // Show MD5 + size so we can confirm the right file was copied
  FS := TFileStream.Create(InputFile, fmOpenRead or fmShareDenyNone);
  try
    Log('MD5 : ' + THashMD5.GetHashString(FS));
    Log('Size: ' + IntToStr(TFile.GetSize(InputFile)) + ' bytes');
  finally
    FS.Free;
  end;

  FileContent := TFile.ReadAllText(InputFile, TEncoding.UTF8);

  try
    FDatabase.RebuildInventoryStart;

    Engine := TCyrusEngine.Create(FileContent);
    try
      Engine.Execute(
        procedure(const Item: TCyrusBagItem)
        var
          ItemIDInt: Integer;
        begin
          if not TryStrToInt(Item.ItemID, ItemIDInt) then
            Exit;  // parser already filters these, but be safe

          FDatabase.InsertInventoryRow(
            Item.OwnerType,
            Item.Owner,
            Item.Realm,
            Item.Storage,
            Item.Container,
            ItemIDInt,
            Item.Count,
            Item.ItemString    // <-- Way 3: raw string preserves quality variants
          );
        end
      );

      FDatabase.RebuildInventoryCommit;

      Log('');
      Log('=== Import complete ===');
      Log(Format('Rows:        %d', [Engine.TotalRows]));
      Log(Format('Unique IDs:  %d', [Engine.UniqueCount]));
      Log(Format('Total stack: %d', [Engine.TotalStack]));
      Log('');

    finally
      Engine.Free;
    end;

  except
    on E: Exception do
    begin
      FDatabase.RebuildInventoryRollback;
      raise;
    end;
  end;
end;

{ ===========================================================================
  Milestones B-E implementation (added to finish the roadmap).
  All UI is created in code (BuildDynamicUI) so no .dfm changes are required.
  =========================================================================== }

// ---------------------------------------------------------------------------
// Milestone E: threading + polish helpers
// ---------------------------------------------------------------------------

procedure TfrmMain.Log(const S: string);
var
  L: string;
begin
  L := S;
  if TThread.CurrentThread.ThreadID = MainThreadID then
    memoInfo.Lines.Add(L)
  else
    TThread.Queue(nil,
      procedure
      begin
        memoInfo.Lines.Add(L);
      end);
end;

procedure TfrmMain.SetBusy(ABusy: Boolean);
begin
  FBusy := ABusy;
  btnExecute.Enabled     := (not ABusy) and HasValidBagSyncPath;
  btnLocate.Enabled      := not ABusy;
  btnImportItems.Enabled := not ABusy;
  if Assigned(btnConsolidate) then
    btnConsolidate.Enabled := not ABusy;
  if Assigned(prog) then
    prog.Visible := ABusy;
  if ABusy then
    Screen.Cursor := crHourGlass
  else
    Screen.Cursor := crDefault;
end;

procedure TfrmMain.RunBagSyncAsync;
begin
  if FBusy then
    Exit;
  if not HasValidBagSyncPath then
  begin
    Log('No valid BagSync.lua path set.');
    Exit;
  end;

  Log('');
  CopyBagSyncToLocal;                 // fast, stays on the main thread
  if not FileExists(GetLocalBagSyncPath) then
  begin
    Log('Local file missing after copy attempt.');
    Exit;
  end;

  Log('Parsing in background: ' + GetLocalBagSyncPath);
  SetBusy(True);

  TTask.Run(
    procedure
    var
      Ok: Boolean;
      ErrMsg: string;
    begin
      Ok := True;
      ErrMsg := '';
      try
        ExecuteParsing;               // heavy work off the UI thread
      except
        on E: Exception do
        begin
          Ok := False;
          ErrMsg := E.Message;
        end;
      end;
      TThread.Queue(nil,
        procedure
        begin
          OnBagSyncDone(Ok, ErrMsg);
        end);
    end);
end;

procedure TfrmMain.OnBagSyncDone(ASuccess: Boolean; const AError: string);
begin
  if ASuccess then
  begin
    if FChainImport then
    begin
      FChainImport := False;
      try
        ExecuteAddonImport;           // import item metadata right after the parse
      except
        on E: Exception do
          Log('Item import error: ' + E.Message);
      end;
    end;
  end
  else
  begin
    FChainImport := False;
    Log('Error during parsing: ' + AError);
  end;
  PopulateOwnerFilters;               // refresh checkboxes from the new data
  SetBusy(False);
  DebugLog('OnBagSyncDone success=' + BoolToStr(ASuccess, True));
  Log('Ready.');
  if ASuccess then
    PageControl1.ActivePage := TabSheet2;   // jump to Participation so the user can pick owners
end;

function TfrmMain.CheckAddonTocVersion(const AAddonLuaPath: string): string;
const
  EXPECTED = 120001;   // bump when the addon .toc is updated for a new patch
var
  WoWRoot, TocPath, S, NumStr: string;
  Lines: TStringList;
  I, Iface: Integer;
begin
  Result := 'TOC check: addon .toc not found (skipped).';
  WoWRoot := GetRetailWoWInstallPath;
  if WoWRoot = '' then
    Exit;

  TocPath := TPath.Combine(WoWRoot,
    '_retail_\Interface\AddOns\OrganizeItemsThroughBagSyncExport\OrganizeItemsThroughBagSyncExport.toc');
  if not TFile.Exists(TocPath) then
    Exit;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(TocPath);
    Iface := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      if S.StartsWith('## Interface:') then
      begin
        NumStr := Trim(Copy(S, Length('## Interface:') + 1, MaxInt));
        Iface := StrToIntDef(NumStr, 0);
        Break;
      end;
    end;

    if Iface = 0 then
      Result := 'TOC check: could not read the "## Interface:" line.'
    else if Iface < EXPECTED then
      Result := Format('TOC check: addon Interface %d looks OUT OF DATE ' +
        '(expected >= %d). Update the .toc after WoW patches.', [Iface, EXPECTED])
    else
      Result := Format('TOC check: addon Interface %d.', [Iface]);
  finally
    Lines.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Milestone B: participation filter
// ---------------------------------------------------------------------------

procedure TfrmMain.BuildDynamicUI;
var
  tabConso: TTabSheet;
  pnlConsoTop, pnlPartTop, detailBar, pnlMainBar: TPanel;
  lbl: TLabel;
begin
  // ============================= Main tab =============================
  // The info memo fills the page; the path, status and buttons sit in a
  // compact bar docked to the bottom, so there is no dead space.
  Panel1.Align   := alClient;
  Panel1.Caption := '';

  pnlMainBar := TPanel.Create(Self);
  pnlMainBar.Parent     := Panel1;
  pnlMainBar.Align      := alBottom;
  pnlMainBar.Height     := 150;
  pnlMainBar.BevelOuter := bvNone;

  // Row 1: green READY / red not-set status. Vertically centered in a tall
  // enough slot so the large bold font is never clipped (was 22px -> clipped).
  Label1.Parent      := pnlMainBar;
  Label1.AutoSize    := False;
  Label1.Transparent := True;
  Label1.Layout      := tlCenter;
  Label1.SetBounds(12, 6, 1120, 30);
  Label1.Anchors     := [akLeft, akTop, akRight];

  // Row 2: file date / OLD warning.
  lblFileDate := TLabel.Create(Self);
  lblFileDate.Parent   := pnlMainBar;
  lblFileDate.AutoSize := False;
  lblFileDate.Layout   := tlCenter;
  lblFileDate.SetBounds(12, 40, 1120, 22);
  lblFileDate.Anchors  := [akLeft, akTop, akRight];
  lblFileDate.Caption  := '';

  // Row 3: path edit.
  Edit1.Parent  := pnlMainBar;
  Edit1.SetBounds(12, 66, 1120, 26);
  Edit1.Anchors := [akLeft, akTop, akRight];

  // Row 4: buttons.
  btnLocate.Parent := pnlMainBar;
  btnLocate.SetBounds(12, 104, 320, 34);

  btnExecute.Parent  := pnlMainBar;
  btnExecute.SetBounds(344, 104, 420, 34);
  btnExecute.Caption := 'Do the magic!  (sync inventory + import item data)';
  btnExecute.Default := True;
  btnExecute.Font.Style := [fsBold];

  btnImportItems.Visible := False;   // merged into the single "Do the magic!" button

  memoInfo.Align := alClient;

  // ========================= Participation tab =======================
  TabSheet2.Caption := '   Participation   ';

  pnlPartTop := TPanel.Create(Self);
  pnlPartTop.Parent     := TabSheet2;
  pnlPartTop.Align      := alTop;
  pnlPartTop.Height     := 64;
  pnlPartTop.BevelOuter := bvNone;

  lblCharsHdr := TLabel.Create(Self);
  lblCharsHdr.Parent := pnlPartTop;
  lblCharsHdr.SetBounds(10, 6, 360, 15);
  lblCharsHdr.Caption := 'Characters (Warband is always included):';

  btnSelAllChars := TButton.Create(Self);
  btnSelAllChars.Parent := pnlPartTop;
  btnSelAllChars.SetBounds(10, 28, 70, 25);
  btnSelAllChars.Caption := 'All';
  btnSelAllChars.OnClick := btnSelAllCharsClick;

  btnSelNoneChars := TButton.Create(Self);
  btnSelNoneChars.Parent := pnlPartTop;
  btnSelNoneChars.SetBounds(84, 28, 70, 25);
  btnSelNoneChars.Caption := 'None';
  btnSelNoneChars.OnClick := btnSelNoneCharsClick;

  lblGuildsHdr := TLabel.Create(Self);
  lblGuildsHdr.Parent := pnlPartTop;
  lblGuildsHdr.SetBounds(400, 6, 200, 15);
  lblGuildsHdr.Caption := 'Guilds:';

  btnSelAllGuilds := TButton.Create(Self);
  btnSelAllGuilds.Parent := pnlPartTop;
  btnSelAllGuilds.SetBounds(400, 28, 70, 25);
  btnSelAllGuilds.Caption := 'All';
  btnSelAllGuilds.OnClick := btnSelAllGuildsClick;

  btnSelNoneGuilds := TButton.Create(Self);
  btnSelNoneGuilds.Parent := pnlPartTop;
  btnSelNoneGuilds.SetBounds(474, 28, 70, 25);
  btnSelNoneGuilds.Caption := 'None';
  btnSelNoneGuilds.OnClick := btnSelNoneGuildsClick;

  FlowPanelChars := TFlowPanel.Create(Self);
  FlowPanelChars.Parent     := TabSheet2;
  FlowPanelChars.Align      := alLeft;
  FlowPanelChars.Width      := 380;
  FlowPanelChars.BevelOuter := bvLowered;

  FlowPanelGuilds.Align := alClient;   // guilds fill the right-hand side

  // ========================= Consolidation tab =======================
  tabConso := TTabSheet.Create(Self);
  tabConso.PageControl := PageControl1;
  tabConso.Caption := '   Consolidation   ';

  pnlConsoTop := TPanel.Create(Self);
  pnlConsoTop.Parent     := tabConso;
  pnlConsoTop.Align      := alTop;
  pnlConsoTop.Height     := 42;
  pnlConsoTop.BevelOuter := bvNone;

  btnConsolidate := TButton.Create(Self);
  btnConsolidate.Parent := pnlConsoTop;
  btnConsolidate.SetBounds(8, 7, 200, 28);
  btnConsolidate.Caption := 'Consolidate!';
  btnConsolidate.OnClick := btnConsolidateClick;

  lblScope := TLabel.Create(Self);
  lblScope.Parent := pnlConsoTop;
  lblScope.SetBounds(224, 14, 360, 15);
  lblScope.Caption := '0 owner(s) selected';

  prog := TProgressBar.Create(Self);
  prog.Parent := pnlConsoTop;
  prog.Align  := alRight;
  prog.AlignWithMargins := True;
  prog.Width  := 200;
  prog.Style  := pbstMarquee;
  prog.Visible := False;

  pnlDetail := TPanel.Create(Self);
  pnlDetail.Parent     := tabConso;
  pnlDetail.Align      := alBottom;
  pnlDetail.Height     := 240;
  pnlDetail.BevelOuter := bvNone;

  detailBar := TPanel.Create(Self);
  detailBar.Parent     := pnlDetail;
  detailBar.Align      := alTop;
  detailBar.Height     := 30;
  detailBar.BevelOuter := bvNone;

  lbl := TLabel.Create(Self);
  lbl.Parent := detailBar;
  lbl.SetBounds(8, 8, 460, 15);
  lbl.Caption := 'Move suggestions (select a row above). Drag the divider to resize:';

  btnCopyMoves := TButton.Create(Self);
  btnCopyMoves.Parent  := detailBar;
  btnCopyMoves.Align   := alRight;
  btnCopyMoves.Width   := 170;
  btnCopyMoves.Caption := 'Copy Instructions';
  btnCopyMoves.OnClick := btnCopyMovesClick;

  memoMoves := TMemo.Create(Self);
  memoMoves.Parent    := pnlDetail;
  memoMoves.Align     := alClient;
  memoMoves.ReadOnly  := True;
  memoMoves.ScrollBars := ssBoth;
  memoMoves.WordWrap  := False;
  memoMoves.Font.Name := 'Consolas';

  // Draggable divider between the grid and the detail panel.
  splitterConso := TSplitter.Create(Self);
  splitterConso.Parent      := tabConso;
  splitterConso.Align       := alBottom;
  splitterConso.Height      := 6;
  splitterConso.MinSize     := 90;
  splitterConso.ResizeStyle := rsUpdate;
  splitterConso.Beveled     := True;

  // Results grid fills the space between the top bar and the splitter.
  StringGrid1.Parent := tabConso;
  StringGrid1.Align  := alClient;
  StringGrid1.DefaultDrawing := True;
  StringGrid1.Options := StringGrid1.Options +
    [goRowSelect, goColSizing, goThumbTracking, goVertLine, goHorzLine];
  StringGrid1.OnSelectCell := StringGrid1SelectCell;
  StringGrid1.OnDrawCell := StringGrid1DrawCell;
  StringGrid1.OnMouseDown := StringGrid1MouseDown;
  StringGrid1.OnMouseUp := StringGrid1MouseUp;
  FHdrDownCol := -1;
  FSortCol := -1;
  FSortState := 0;
  PopulateResultsGrid;

  // All controls now exist: refresh the Main-tab status line + file date.
  UpdateUIAfterLoad(HasValidBagSyncPath);
end;

procedure TfrmMain.PopulateOwnerFilters;
var
  Qry: TFDQuery;
  cb: TCheckBox;
  OT, Nm, Rlm: string;
  OID: Integer;
  IsGuild, IsWarband: Boolean;
begin
  if not Assigned(FlowPanelChars) then
    Exit;

  while FlowPanelChars.ControlCount > 0 do
    FlowPanelChars.Controls[0].Free;
  while FlowPanelGuilds.ControlCount > 0 do
    FlowPanelGuilds.Controls[0].Free;
  FOwnerChecks.Clear;

  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := FDatabase.Connection;
    Qry.SQL.Text :=
      'SELECT OwnerID, OwnerType, OwnerName, Realm FROM Owners ' +
      'ORDER BY OwnerType, OwnerName COLLATE NOCASE;';
    Qry.Open;
    while not Qry.Eof do
    begin
      OID := Qry.FieldByName('OwnerID').AsInteger;
      OT  := Qry.FieldByName('OwnerType').AsString;
      Nm  := Qry.FieldByName('OwnerName').AsString;
      Rlm := Qry.FieldByName('Realm').AsString;

      cb := TCheckBox.Create(Self);
      cb.Tag := OID;
      cb.Checked := True;
      cb.OnClick := OwnerCheckboxClick;
      cb.Width := 360;
      // Stable identity for INI persistence (OwnerID churns on every rebuild).
      cb.Hint := OT + '|' + Nm + '|' + Rlm;

      // Classify by stored OwnerType OR the trailing marker in the name, so even
      // a database built before the parser fix lands guilds/warband correctly:
      //   trailing U+00A9 (copyright) => Guild, U+00A7 (section) => Warband.
      IsGuild := SameText(OT, 'Guild') or
        ((Nm <> '') and (Ord(Nm[Length(Nm)]) = $A9));
      IsWarband := SameText(OT, 'Warband') or
        ((Nm <> '') and (Ord(Nm[Length(Nm)]) = $A7));

      if IsGuild then
      begin
        cb.Caption := Format('%s (Guild)', [Nm]);
        cb.Parent := FlowPanelGuilds;
      end
      else if IsWarband then
      begin
        cb.Caption := Format('%s [Warband - always included]', [Nm]);
        cb.Enabled := False;           // forced on
        cb.Parent := FlowPanelChars;
      end
      else
      begin
        cb.Caption := Format('%s @ %s', [Nm, Rlm]);
        cb.Parent := FlowPanelChars;
      end;

      FOwnerChecks.Add(cb);
      Qry.Next;
    end;
    Qry.Close;
  finally
    Qry.Free;
  end;

  LoadOwnerFilterFromIni;
  UpdateScopeLabel;
end;

procedure TfrmMain.OwnerCheckboxClick(Sender: TObject);
begin
  if FLoadingFilter then
    Exit;
  UpdateScopeLabel;
  SaveOwnerFilterToIni;
end;

function TfrmMain.GetSelectedOwnerIDs: TArray<Integer>;
var
  cb: TCheckBox;
  L: TList<Integer>;
begin
  L := TList<Integer>.Create;
  try
    for cb in FOwnerChecks do
      if cb.Checked then
        L.Add(cb.Tag);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

procedure TfrmMain.SaveOwnerFilterToIni;
var
  Ini: TIniFile;
  cb: TCheckBox;
begin
  if (FOwnerChecks = nil) or (FOwnerChecks.Count = 0) then
    Exit;
  Ini := TIniFile.Create(GetIniPath);
  try
    for cb in FOwnerChecks do
      Ini.WriteBool('OwnerFilter', OwnerIniKey(cb.Hint), cb.Checked);
  finally
    Ini.Free;
  end;
end;

procedure TfrmMain.LoadOwnerFilterFromIni;
var
  Ini: TIniFile;
  cb: TCheckBox;
begin
  FLoadingFilter := True;
  try
    Ini := TIniFile.Create(GetIniPath);
    try
    for cb in FOwnerChecks do
      if cb.Enabled then               // never override forced Warband
        cb.Checked := Ini.ReadBool('OwnerFilter', OwnerIniKey(cb.Hint), True);
    finally
      Ini.Free;
    end;
  finally
    FLoadingFilter := False;
  end;
end;

procedure TfrmMain.UpdateScopeLabel;
var
  cb: TCheckBox;
  n: Integer;
begin
  n := 0;
  for cb in FOwnerChecks do
    if cb.Checked then
      Inc(n);
  if Assigned(lblScope) then
    lblScope.Caption := Format('%d owner(s) selected', [n]);
end;

procedure TfrmMain.SetOwnersChecked(AParent: TWinControl; AValue: Boolean);
var
  cb: TCheckBox;
begin
  FLoadingFilter := True;
  try
    for cb in FOwnerChecks do
      if (cb.Parent = AParent) and cb.Enabled then
        cb.Checked := AValue;
  finally
    FLoadingFilter := False;
  end;
  UpdateScopeLabel;
  SaveOwnerFilterToIni;
end;

procedure TfrmMain.btnSelAllCharsClick(Sender: TObject);
begin
  SetOwnersChecked(FlowPanelChars, True);
end;

procedure TfrmMain.btnSelNoneCharsClick(Sender: TObject);
begin
  SetOwnersChecked(FlowPanelChars, False);
end;

procedure TfrmMain.btnSelAllGuildsClick(Sender: TObject);
begin
  SetOwnersChecked(FlowPanelGuilds, True);
end;

procedure TfrmMain.btnSelNoneGuildsClick(Sender: TObject);
begin
  SetOwnersChecked(FlowPanelGuilds, False);
end;

// ---------------------------------------------------------------------------
// Milestone C: consolidation engine + results grid
// ---------------------------------------------------------------------------

function TfrmMain.BindTypeToStr(ABind: Integer): string;
begin
  case ABind of
    0: Result := 'Free';
    1: Result := 'BoP';
    2: Result := 'BoE';
    3: Result := 'BoU';
    4: Result := 'Quest';
  else
    Result := '?';
  end;
end;

function TfrmMain.QualityToColor(AQuality: Integer): TColor;
begin
  case AQuality of
    0: Result := RGB(157, 157, 157);   // Poor
    1: Result := RGB( 20,  20,  20);   // Common
    2: Result := RGB( 30, 160,  30);   // Uncommon
    3: Result := RGB(  0, 112, 221);   // Rare
    4: Result := RGB(163,  53, 238);   // Epic
    5: Result := RGB(255, 128,   0);   // Legendary
  else
    Result := clWindowText;
  end;
end;

procedure TfrmMain.btnConsolidateClick(Sender: TObject);
begin
  RunConsolidationUI;
end;

procedure TfrmMain.RunConsolidationUI;
var
  ids: TArray<Integer>;
  Qry: TFDQuery;
  ItemCount: Integer;
  RawResults: TList<TConsolidationResult>;
  R: TConsolidationResult;
begin
  ids := GetSelectedOwnerIDs;
  if Length(ids) = 0 then
  begin
    MessageDlg('Select at least one character or guild on the Participation tab.',
      mtInformation, [mbOK], 0);
    Exit;
  end;

  // Warn if nothing has been loaded yet (user jumped straight to this tab).
  ItemCount := 0;
  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := FDatabase.Connection;
    Qry.SQL.Text := 'SELECT COUNT(*) AS C FROM Inventory;';
    Qry.Open;
    ItemCount := Qry.Fields[0].AsInteger;
    Qry.Close;
  finally
    Qry.Free;
  end;
  if ItemCount = 0 then
  begin
    MessageDlg('No inventory has been loaded yet.' + sLineBreak + sLineBreak +
      'Go to the Main tab and click "Do the magic!" first, to read your BagSync ' +
      'data and import item details.', mtWarning, [mbOK], 0);
    PageControl1.ActivePageIndex := 0;
    Exit;
  end;

  ItemCount := 0;
  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := FDatabase.Connection;
    Qry.SQL.Text := 'SELECT COUNT(*) AS C FROM Items;';
    Qry.Open;
    ItemCount := Qry.Fields[0].AsInteger;
    Qry.Close;
  finally
    Qry.Free;
  end;

  if ItemCount = 0 then
  begin
    if MessageDlg('The Items table is empty, so item names, bind types and stack ' +
       'sizes are unknown and consolidation cannot be computed.' + sLineBreak + sLineBreak +
       'Import item data now?', mtWarning, [mbYes, mbNo], 0) <> mrYes then
      Exit;
    try
      ExecuteAddonImport;
    except
      on E: Exception do
      begin
        Log('Item import error: ' + E.Message);
        MessageDlg('Item import failed:' + sLineBreak + E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
  end;

  // Compute, then keep only items that can actually MOVE between your characters.
  // Bound items (BoP / Quest / Soulbound) are excluded from the suggestions.
  Screen.Cursor := crHourGlass;
  if Assigned(prog) then
    prog.Visible := True;
  try
    RawResults := FConsolidator.RunConsolidation(ids);
    try
      FreeAndNil(FLastResults);
      FLastResults := TList<TConsolidationResult>.Create;
      for R in RawResults do
        if R.FreelyMoveable then
          FLastResults.Add(R);
    finally
      RawResults.Free;
    end;

    FSortCol := -1;        // fresh result set -> engine's default order
    FSortState := 0;
    PopulateResultsGrid;
  finally
    if Assigned(prog) then
      prog.Visible := False;
    Screen.Cursor := crDefault;
  end;

  if Assigned(memoMoves) then
    memoMoves.Lines.Clear;

  Log(Format('Consolidation: %d movable item(s) with savings across %d owner(s).',
    [FLastResults.Count, Length(ids)]));

  if FLastResults.Count > 0 then
    ShowMoveDetailForRow(0);
end;

procedure TfrmMain.PopulateResultsGrid;
const
  ResultHeaders: array[0..6] of string =
    ('Item', 'Bind', 'Max', 'Owners', 'Total', 'Min Slots', 'Saveable');
var
  I: Integer;
  R: TConsolidationResult;
  NameStr: string;
  arrow: string;
begin
  StringGrid1.ColCount := 7;
  StringGrid1.FixedRows := 1;

  // "Move?" column removed: every listed item is movable (bound items are filtered
  // out before display). An arrow marks the column the grid is currently sorted by.
  arrow := '';
  if FSortState = 1 then
    arrow := ' ' + Char($2191)         // up arrow = ascending
  else if FSortState = 2 then
    arrow := ' ' + Char($2193);        // down arrow = descending

  for I := 0 to High(ResultHeaders) do
    if I = FSortCol then
      StringGrid1.Cells[I, 0] := ResultHeaders[I] + arrow
    else
      StringGrid1.Cells[I, 0] := ResultHeaders[I];

  StringGrid1.ColWidths[0] := 300;
  StringGrid1.ColWidths[1] := 90;
  StringGrid1.ColWidths[2] := 55;
  StringGrid1.ColWidths[3] := 60;
  StringGrid1.ColWidths[4] := 70;
  StringGrid1.ColWidths[5] := 75;
  StringGrid1.ColWidths[6] := 75;

  if (FLastResults = nil) or (FLastResults.Count = 0) then
  begin
    StringGrid1.RowCount := 2;
    StringGrid1.Rows[1].Clear;
    Exit;
  end;

  StringGrid1.RowCount := FLastResults.Count + 1;
  for I := 0 to FLastResults.Count - 1 do
  begin
    R := FLastResults[I];
    NameStr := R.Name;
    if NameStr = '' then
      NameStr := Format('(item %d)', [R.ItemID]);
    if not R.MetadataKnown then
      NameStr := NameStr + '  [no metadata]';

    StringGrid1.Cells[0, I + 1] := NameStr;
    StringGrid1.Cells[1, I + 1] := BindLabel(R);
    StringGrid1.Cells[2, I + 1] := IntToStr(R.MaxStack);
    StringGrid1.Cells[3, I + 1] := IntToStr(R.OwnerCount);
    StringGrid1.Cells[4, I + 1] := IntToStr(R.TotalCount);
    StringGrid1.Cells[5, I + 1] := IntToStr(R.MinSlotsNeeded);
    StringGrid1.Cells[6, I + 1] := IntToStr(R.SlotsSaveable);
  end;
  StringGrid1.Row := 1;
end;

procedure TfrmMain.StringGrid1SelectCell(Sender: TObject; ACol, ARow: Integer;
  var CanSelect: Boolean);
begin
  CanSelect := True;
  if (ARow >= 1) and Assigned(FLastResults) and (ARow - 1 < FLastResults.Count) then
    ShowMoveDetailForRow(ARow - 1);
end;

procedure TfrmMain.StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer;
  Rect: TRect; State: TGridDrawState);
var
  G: TStringGrid;
  Txt: string;
  Selected: Boolean;
begin
  if ARow = 0 then Exit;        // header: default painting
  if ACol <> 0 then Exit;       // only the Item name is custom-drawn (quality colour)

  G := StringGrid1;
  Txt := G.Cells[ACol, ARow];
  Selected := gdSelected in State;

  if Selected then
    G.Canvas.Brush.Color := clHighlight
  else
    G.Canvas.Brush.Color := clWindow;
  G.Canvas.FillRect(Rect);

  if Selected then
    G.Canvas.Font.Color := clHighlightText
  else if (ARow - 1 >= 0) and Assigned(FLastResults) and (ARow - 1 < FLastResults.Count) then
    G.Canvas.Font.Color := QualityToColor(FLastResults[ARow - 1].Quality)
  else
    G.Canvas.Font.Color := clWindowText;

  G.Canvas.TextRect(Rect, Rect.Left + 4, Rect.Top + 2, Txt);
end;

procedure TfrmMain.StringGrid1MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  ac, ar: Integer;
begin
  FHdrDownCol := -1;
  if Button <> mbLeft then Exit;
  StringGrid1.MouseToCell(X, Y, ac, ar);
  if ar = 0 then                                // mouse went down on the header row
  begin
    FHdrDownCol := ac;
    FHdrDownX := X;
  end;
end;

procedure TfrmMain.StringGrid1MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  ac, ar: Integer;
begin
  if Button <> mbLeft then Exit;
  if FHdrDownCol < 0 then Exit;                 // did not start on a header cell
  StringGrid1.MouseToCell(X, Y, ac, ar);
  // Same header cell, and the X barely moved (so it is a click, not a column resize).
  if (ar = 0) and (ac = FHdrDownCol) and (Abs(X - FHdrDownX) < 5) then
    CycleSortColumn(ac);
  FHdrDownCol := -1;
end;

procedure TfrmMain.CycleSortColumn(ACol: Integer);
begin
  if (FLastResults = nil) or (FLastResults.Count = 0) then Exit;
  if (ACol < 0) or (ACol > 6) then Exit;

  if ACol = FSortCol then
  begin
    Inc(FSortState);                            // ascending -> descending -> default
    if FSortState > 2 then
    begin
      FSortState := 0;
      FSortCol := -1;
    end;
  end
  else
  begin
    FSortCol := ACol;
    FSortState := 1;                            // first click on a column = ascending
  end;

  ApplyResultSort;
end;

procedure TfrmMain.ApplyResultSort;
var
  col, dir: Integer;
begin
  if (FLastResults = nil) or (FLastResults.Count = 0) then
    Exit;

  col := FSortCol;
  if FSortState = 2 then dir := -1 else dir := 1;

  if (col < 0) or (FSortState = 0) then
    // Default order: most slots saveable first, then biggest totals, then name.
    FLastResults.Sort(TComparer<TConsolidationResult>.Construct(
      function(const A, B: TConsolidationResult): Integer
      begin
        Result := B.SlotsSaveable - A.SlotsSaveable;
        if Result = 0 then Result := CompareValue(B.TotalCount, A.TotalCount);
        if Result = 0 then Result := CompareText(A.Name, B.Name);
      end))
  else
    FLastResults.Sort(TComparer<TConsolidationResult>.Construct(
      function(const A, B: TConsolidationResult): Integer
      begin
        case col of
          0: Result := CompareText(A.Name, B.Name);
          1: Result := CompareText(BindLabel(A), BindLabel(B));
          2: Result := A.MaxStack - B.MaxStack;
          3: Result := A.OwnerCount - B.OwnerCount;
          4: Result := CompareValue(A.TotalCount, B.TotalCount);
          5: Result := A.MinSlotsNeeded - B.MinSlotsNeeded;
          6: Result := A.SlotsSaveable - B.SlotsSaveable;
        else
          Result := 0;
        end;
        Result := Result * dir;
      end));

  PopulateResultsGrid;
  if FLastResults.Count > 0 then
  begin
    StringGrid1.Row := 1;
    ShowMoveDetailForRow(0);
  end;
end;

// ---------------------------------------------------------------------------
// Milestone D: move suggestions detail
// ---------------------------------------------------------------------------

function TfrmMain.LocDesc(const ALoc: TItemLocation): string;
begin
  if SameText(ALoc.OwnerType, 'Character') then
    Result := Format('%s @ %s / %s / %s',
      [ALoc.OwnerName, ALoc.Realm, ALoc.StorageName, ALoc.Container])
  else
    Result := Format('%s (%s) / %s / %s',
      [ALoc.OwnerName, ALoc.OwnerType, ALoc.StorageName, ALoc.Container]);
end;

function TfrmMain.StorageMoveNote(const AStorage: string; AsDestination: Boolean): string;
begin
  Result := '';
  if AsDestination then
  begin
    if SameText(AStorage, 'bank') or SameText(AStorage, 'reagentbank') then
      Result := '   [visit bank NPC]'
    else if SameText(AStorage, 'guildtab') then
      Result := '   [needs guild rank permission]';
  end
  else
  begin
    if SameText(AStorage, 'mail') or SameText(AStorage, 'auction') then
      Result := '   [pending - not immediately accessible]';
  end;
end;

function TfrmMain.BuildMoveInstructions(const R: TConsolidationResult;
  ALocs: TList<TItemLocation>): TStringList;
var
  NameStr: string;
  Loc: TItemLocation;
  Arr: TArray<TItemLocation>;
  pair: TPair<Integer, TList<TItemLocation>>;
  ownerList: TList<TItemLocation>;
  Work: TList<TItemLocation>;
  Groups: TObjectDictionary<Integer, TList<TItemLocation>>;

  procedure PackAndEmit(AArr: TArray<TItemLocation>; ADest: TStringList;
    const AName: string; AMax: Integer);
  var
    i, j: Integer;
    space, moveQty: Int64;
  begin
    if Length(AArr) < 2 then
      Exit;
    TArray.Sort<TItemLocation>(AArr, TComparer<TItemLocation>.Construct(
      function(const A, B: TItemLocation): Integer
      begin
        Result := CompareValue(B.Count, A.Count);
      end));
    i := 0;
    j := High(AArr);
    while i < j do
    begin
      space := AMax - AArr[i].Count;
      if space <= 0 then
      begin
        Inc(i);
        Continue;
      end;
      if AArr[j].Count <= 0 then
      begin
        Dec(j);
        Continue;
      end;
      moveQty := space;
      if AArr[j].Count < moveQty then
        moveQty := AArr[j].Count;
      ADest.Add(Format('  Move %d x %s', [moveQty, AName]));
      ADest.Add(Format('       FROM %s%s',
        [LocDesc(AArr[j]), StorageMoveNote(AArr[j].StorageName, False)]));
      ADest.Add(Format('       TO   %s%s',
        [LocDesc(AArr[i]), StorageMoveNote(AArr[i].StorageName, True)]));
      AArr[i].Count := AArr[i].Count + moveQty;
      AArr[j].Count := AArr[j].Count - moveQty;
      if AArr[j].Count = 0 then
        Dec(j);
    end;
  end;

begin
  Result := TStringList.Create;
  NameStr := R.Name;
  if NameStr = '' then
    NameStr := Format('(item %d)', [R.ItemID]);

  Work := TList<TItemLocation>.Create;
  try
    for Loc in ALocs do
      if not SameText(Loc.StorageName, 'void') then   // void cannot be src/dst
        Work.Add(Loc);

    if R.FreelyMoveable then
    begin
      Arr := Work.ToArray;
      PackAndEmit(Arr, Result, NameStr, R.MaxStack);
    end
    else
    begin
      Groups := TObjectDictionary<Integer, TList<TItemLocation>>.Create([doOwnsValues]);
      try
        for Loc in Work do
        begin
          if not Groups.TryGetValue(Loc.OwnerID, ownerList) then
          begin
            ownerList := TList<TItemLocation>.Create;
            Groups.Add(Loc.OwnerID, ownerList);
          end;
          ownerList.Add(Loc);
        end;
        for pair in Groups do
        begin
          Arr := pair.Value.ToArray;
          PackAndEmit(Arr, Result, NameStr, R.MaxStack);
        end;
      finally
        Groups.Free;
      end;
    end;
  finally
    Work.Free;
  end;
end;

procedure TfrmMain.ShowMoveDetailForRow(RowIndex: Integer);
var
  R: TConsolidationResult;
  Locs: TList<TItemLocation>;
  SL: TStringList;
  Loc: TItemLocation;
  NameStr: string;
begin
  if not Assigned(memoMoves) then
    Exit;
  if (FLastResults = nil) or (RowIndex < 0) or (RowIndex >= FLastResults.Count) then
    Exit;

  R := FLastResults[RowIndex];
  Locs := FConsolidator.GetItemLocations(R.ItemID, R.ItemString, GetSelectedOwnerIDs);
  try
    memoMoves.Lines.BeginUpdate;
    try
      memoMoves.Lines.Clear;
      NameStr := R.Name;
      if NameStr = '' then
        NameStr := Format('(item %d)', [R.ItemID]);

      memoMoves.Lines.Add(Format('%s   -   ItemID %d', [NameStr, R.ItemID]));
      memoMoves.Lines.Add(Format(
        'Bind: %s (%s)    MaxStack: %d    Total: %d    Occupied slots: %d    ' +
        'Min needed: %d    Saveable: %d',
        [BindLabel(R),
         IfThen(R.FreelyMoveable, 'moveable among your characters', 'bound to one character'),
         R.MaxStack, R.TotalCount, R.StackCount, R.MinSlotsNeeded, R.SlotsSaveable]));
      if not R.FreelyMoveable then
        memoMoves.Lines.Add(
          'Note: this item is bound to a character (BoP / Quest / Soulbound) - stacks can only be ' +
          'merged within the same character, never moved to another one.');
      if not R.MetadataKnown then
        memoMoves.Lines.Add(
          'Note: no metadata imported for this item; MaxStack assumed. Run "Import Item Data" for accuracy.');
      memoMoves.Lines.Add('');
      memoMoves.Lines.Add('Sources (current locations):');
      for Loc in Locs do
        memoMoves.Lines.Add(Format('  %d x  %s', [Loc.Count, LocDesc(Loc)]));
      memoMoves.Lines.Add('');
      memoMoves.Lines.Add('Suggested moves:');

      SL := BuildMoveInstructions(R, Locs);
      try
        if SL.Count = 0 then
          memoMoves.Lines.Add('  (nothing to do)')
        else
          memoMoves.Lines.AddStrings(SL);
      finally
        SL.Free;
      end;
    finally
      memoMoves.Lines.EndUpdate;
    end;
  finally
    Locs.Free;
  end;
end;

procedure TfrmMain.btnCopyMovesClick(Sender: TObject);
begin
  if Assigned(memoMoves) and (memoMoves.Lines.Count > 0) then
  begin
    Clipboard.AsText := memoMoves.Lines.Text;
    Log('Move instructions copied to clipboard.');
  end;
end;


function TfrmMain.BindLabel(const R: TConsolidationResult): string;
var
  C: string;
begin
  C := LowerCase(Trim(R.BindCategory));
  if C = 'tradeable' then Result := 'Free'
  else if C = 'bind-on-equip' then Result := 'BoE'
  else if C = 'bind-on-use' then Result := 'BoU'
  else if C = 'bind-on-pickup' then Result := 'BoP'
  else if C = 'quest-item' then Result := 'Quest'
  else if C = 'warbound' then Result := 'Warbound'
  else if C = 'warbound-boe' then Result := 'Warb/BoE'
  else if C = 'account-bound' then Result := 'Account'
  else if C = 'soulbound' then Result := 'Soulbound'
  else Result := BindTypeToStr(R.BindType);
end;

function TfrmMain.BagSyncFileWarning: string;
var
  dt: TDateTime;
  ageDays: Integer;
begin
  Result := '';
  if not HasValidBagSyncPath then Exit;
  dt := GetFileLastModifiedDateTime(Edit1.Text);
  if dt <= 0 then Exit;
  ageDays := Trunc(Now - dt);
  Result := Format('BagSync.lua last saved %s  (%d day(s) ago).',
    [FormatDateTime('yyyy-mm-dd hh:nn', dt), ageDays]);
  if ageDays >= 7 then
    Result := Result + '  This looks OLD - log in to WoW and /reload to refresh it.';
end;

procedure TfrmMain.DebugLog(const S: string);
{$IFDEF DEBUG}
var
  W: TStreamWriter;
{$ENDIF}
begin
{$IFDEF DEBUG}
  try
    W := TStreamWriter.Create(ExtractFilePath(ParamStr(0)) + 'debug_log.txt', True, TEncoding.UTF8);
    try
      W.WriteLine(Format('[%s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), S]));
    finally
      W.Free;
    end;
  except
    // debug logging must never disrupt the app
  end;
{$ELSE}
  if S = '' then Exit;   // reference S so Release builds raise no hint
{$ENDIF}
end;
function TfrmMain.OwnerIniKey(const S: string): string;
var
  h: Int64;
  i: Integer;
begin
  // Stable, ASCII-safe INI key for an owner identity (survives the OwnerID
  // churn of a full rebuild). FNV-1a 32-bit hash kept in an Int64 and masked
  // to 32 bits each step, so it never overflows regardless of range checks.
  h := 2166136261;
  for i := 1 to Length(S) do
    h := ((h xor Ord(S[i])) * 16777619) and $FFFFFFFF;
  Result := 'O' + IntToStr(h);
end;
procedure TfrmMain.FormActivate(Sender: TObject);
begin
  // The addon deploy needs the resolved BagSync.lua path to locate the AddOns
  // folder, so it is driven by TryStartupDeploy, which fires exactly once -
  // whichever of (window activated) / (async WoW detection finished) is last.
  TryStartupDeploy;
end;

procedure TfrmMain.DeployAddonOnStartup;
var
  dir, err: string;
begin
  dir := StartupAddonDir(Edit1.Text);
  if dir = '' then
  begin
    DebugLog('Addon deploy skipped: no _retail_ path from "' + Edit1.Text + '".');
    Exit;
  end;

  memoInfo.Lines.Add('');
  if IsAddonDeployTestMode then
    memoInfo.Lines.Add('[TEST MODE] Deploying bundled companion addon to a local test folder:')
  else
    memoInfo.Lines.Add('Checking the bundled companion addon in your WoW AddOns folder:');

  Screen.Cursor := crHourGlass;
  try
    DeployCompanionAddon(dir, memoInfo.Lines, err);  // logs its own outcome; never raises
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.TryStartupDeploy;
begin
  // Deploy exactly once, and only after the async WoW-path resolution has run,
  // so Edit1.Text holds the detected (or INI-fallback) BagSync.lua path.
  if FStartupDeployDone then
    Exit;
  if not FStartupPathResolved then
    Exit;
  FStartupDeployDone := True;
  DeployAddonOnStartup;
end;

procedure TfrmMain.StartWoWDetection;
begin
  // Run only the pure, UI-free drive scan on a worker thread, then hand the
  // result back to the main thread. ResolveRetailWoWAccountPathTakeTwo may show
  // a dialog, so it must stay on the main thread (in OnWoWDetected).
  UDetectAlive := True;
  TTask.Run(
    procedure
    var
      Root: string;
    begin
      try
        Root := GetRetailWoWInstallPath;
      except
        Root := '';   // never leave the detection hanging on an error
      end;
      TThread.Queue(nil,
        procedure
        begin
          if not UDetectAlive then   // form already destroyed -> do nothing
            Exit;
          OnWoWDetected(Root);
        end);
    end);
end;

procedure TfrmMain.OnWoWDetected(const AWoWRoot: string);
var
  AccountPath, FinalPath: string;
begin
  Screen.Cursor := crDefault;

  if AWoWRoot = '' then
  begin
    memoInfo.Lines.Add('');
    memoInfo.Lines.Add('Retail WoW installation could not be found automatically.');
    memoInfo.Lines.Add('Please use "Locate BagSync.lua" to set the path manually.');
    UpdateUIAfterLoad(False);
  end
  else
  begin
    AccountPath := ResolveRetailWoWAccountPathTakeTwo(AWoWRoot);
    if AccountPath = '' then
    begin
      memoInfo.Lines.Add('');
      memoInfo.Lines.Add('WoW found but account folder could not be determined.');
      memoInfo.Lines.Add('Please use "Locate BagSync.lua" to set the path manually.');
      UpdateUIAfterLoad(False);
    end
    else
    begin
      FinalPath  := TPath.Combine(AccountPath, 'SavedVariables\BagSync.lua');
      Edit1.Text := FinalPath;
      if HasValidBagSyncPath then
        UpdateUIAfterLoad(True)
      else
      begin
        memoInfo.Lines.Add('');
        memoInfo.Lines.Add('Account found, but BagSync.lua is missing at:');
        memoInfo.Lines.Add('  ' + FinalPath);
        UpdateUIAfterLoad(False);
      end;
    end;
  end;

  // INI round-trip: if auto-detect didn't yield a valid path, fall back to the INI.
  if not HasValidBagSyncPath then
  begin
    LoadFromIni;
    if HasValidBagSyncPath then
      UpdateUIAfterLoad(True);
  end;

  FStartupPathResolved := True;
  TryStartupDeploy;   // path is known now -> safe to deploy the companion addon
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // Milestone E: do not tear the form (and FDatabase) down while the async
  // BagSync parse is still running on a worker thread.
  if FBusy then
  begin
    CanClose := False;
    Log('Please wait - a BagSync parse is still running.');
  end
  else
    CanClose := True;
end;

// ===========================================================================
//  PROJECT HANDOFF / STATUS NOTES  (last updated 2026-10-20)
//  OrganizeEntropy = "OrganizeItemsThroughBagSync" - Delphi 12 / Win32 VCL app.
//  Reads the WoW BagSync addon SavedVariables (BagSync.lua), stores every item
//  across characters / guild banks / the Warband bank in a local SQLite DB
//  (FireDAC), and suggests how to merge partial stacks to free bag/bank/tab slots.
//
//  ---- UNITS / FILES -------------------------------------------------------
//  MainFrm.pas/.dfm       UI + orchestration. MOST of the UI is built IN CODE in
//                         BuildDynamicUI (Participation + Consolidation tabs and
//                         the Main-tab bottom bar). The .dfm has only the base
//                         controls + PageControl.
//  CyrusParser.pas        BagSync.lua parser. MUST stay UTF-8 WITH BOM (it holds
//                         the copyright/section-sign marker literals). Owner type
//                         is compared by Unicode code point so it never depends on
//                         the file encoding: Guild = name ends U+00A9, Warband =
//                         U+00A7 (a TOP-level section, depth 4, with no realm).
//  CyrusDB.pas            FireDAC/SQLite. RebuildInventoryStart clears Inventory +
//                         Owners + StorageTypes (full rebuild, no stale owners).
//  CyrusAddonImporter.pas Parses the companion addon export into the Items table.
//  CyrusConsolidator.pas  Consolidation engine. "Moveable among your own chars" =
//                         Free/BoE/BoU/Warbound/Account-Bound; "bound" = BoP/Quest/
//                         Soulbound. Uses Items.BindCategory, falls back to numeric
//                         BindType.
//  CyrusAddonDeploy.pas   Embeds about.txt + the 3 companion-addon files (addon.res)
//                         and deploys the addon to the WoW AddOns folder. Holds the
//                         ADDON_DEPLOY_TEST toggle (see below).
//  WoWPathDetector.pas    Finds the retail WoW install.
//  about.txt              Main-tab help text (embedded). Edit it, then rebuild
//                         addon.res to change the in-app text.
//  addon.rc / addon.res   Resource script + compiled resource (ABOUT_TEXT + ADDON_*).
//
//  ---- DONE (built clean; verified by running unless noted) ----------------
//  * Milestones A-E (earlier): parser encoding/guild/warband fix; full DB rebuild;
//    consolidation engine; single "Do the magic!" (parse + item import in one go);
//    participation filter; docs (README.md, README_TOO, LICENSE).
//  * Bottom-bar truncation fixed (the bold green "READY" status line was clipped).
//  * Help text moved out of code: ~40 memoInfo.Lines.Add replaced by one
//    memoInfo.Lines.Text := GetAboutText (loads embedded about.txt).
//  * BoP help wording corrected: the stored bindType is the item-TYPE rule ("binds
//    when picked up"); any copy already in bags/bank is in fact Soulbound to that
//    character. Behaviour was already correct - only the wording changed.
//  * Companion addon (3 files) + about text embedded in the exe (verified
//    byte-identical by reading the PE resources back out of the built exe).
//  * Auto-deploy of the companion addon on startup: one-time guarded OnActivate
//    (FStartupDeployDone) -> DeployAddonOnStartup. Runs AFTER the window is painted,
//    and DeployCompanionAddon never raises, so it cannot block/break startup. Shows
//    an hourglass; logs to the memo; idempotent (byte-compare, writes only changes).
//    VERIFIED: test mode deployed 3 files byte-identical + 2nd run "already up to
//    date" (timestamps unchanged); release mode verified on a THROWAWAY fake
//    _retail_ tree (derived ..._retail_\Interface\AddOns\<addon> from BagSync.lua).
//
//  ---- ADDON DEPLOY TOGGLE (important) -------------------------------------
//  Top of CyrusAddonDeploy.pas:  {$DEFINE ADDON_DEPLOY_TEST}
//    ENABLED (current) = deploy to a local "_addon_deploy_test" folder beside the
//                        exe (safe on a machine with no WoW).
//    COMMENT IT OUT before release = deploy to the real WoW AddOns folder, derived
//                        by walking the BagSync.lua path up to _retail_ then into
//                        Interface\AddOns\OrganizeItemsThroughBagSyncExport.
//  NOTE: deploy to a REAL WoW install was NOT tested (no WoW on the dev laptop). On
//  a Program Files install the first write may need elevation; the idempotent check
//  means no write when the files already match.
//
//  ---- DONE 2026-10-21 (agreed bucket; built clean + runtime-verified) -----
//   1. Busy feedback: Screen.Cursor := crHourGlass during the startup WoW scan
//      (FormCreate) and around the consolidation compute (RunConsolidationUI, which
//      also shows the marquee prog bar). Parse already uses SetBusy.
//   2. On a successful "Do the magic!": auto-switch to the Participation tab
//      (OnBagSyncDone: if ASuccess then PageControl1.ActivePage := TabSheet2).
//      VERIFIED on screen.
//   3. Consolidation grid: "Move?" column REMOVED (7 cols now); non-movable (bound)
//      items are EXCLUDED from results (RunConsolidationUI keeps only
//      R.FreelyMoveable); header-click sort implemented via OnMouseDown/OnMouseUp +
//      MouseToCell (NOTE: OnFixedCellClick did NOT fire reliably on this
//      goColSizing grid - use the mouse handlers). Cycle per column: 1st=ascending,
//      2nd=descending, 3rd=back to default (SlotsSaveable desc, TotalCount desc,
//      Name). Active sort column shows a Char($2191)/Char($2193) arrow. All VERIFIED.
//
//  ---- NOT DONE YET / NEXT -------------------------------------------------
//  (waiting on user)
//   4. BagBrother positioning text for the About/Main tab (how to frame this tool
//      vs the BagBrother addon).
//   5. Confirm the real deploy path + run a real-WoW deploy test.
//  (optional)
//   6. When deploying the .toc, stamp its "## Interface:" with the detected client
//      build so the addon is never flagged out of date.
//
//  ---- HOW TO CONTINUE ON ANOTHER MACHINE ----------------------------------
//  * Delphi 12 (BDS 22.0), Win32. Build with the IDE.
//  * Keep CyrusParser.pas as UTF-8 WITH BOM.
//  * To change about.txt or the embedded addon, rebuild the resource:
//        brcc32 addon.rc      (default output addon.res; the -fo flag misparses)
//    then rebuild the project. Keep addon.rc + about.txt + the 3 files under
//    OrganizeItemsThroughBagSyncExport\ so addon.res can be regenerated.
//  * Runtime test without WoW: set Win32\Debug\OrganizeItemsThroughBagSync.ini
//    BagSyncPath to a BagSync.lua and AddonExportPath to the companion export DATA
//    file (OrganizeItemsThroughBagSyncExport.lua.bak). The plain .lua in that folder
//    is the addon CODE - do NOT feed it to the item importer.
// ===========================================================================

end.
