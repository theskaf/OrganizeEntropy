unit MainFrm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, System.IniFiles, System.StrUtils, System.DateUtils,
  Vcl.ExtCtrls, Vcl.Grids, Vcl.ComCtrls,
  System.Generics.Collections, System.IOUtils, WoWPathDetector,
  CyrusParser, CyrusDB, System.Hash, System.UITypes;

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
    procedure FormCreate(Sender: TObject);
    procedure btnLocateClick(Sender: TObject);
    procedure btnExecuteClick(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormDestroy(Sender: TObject);

  private
    FDatabase: TCyrusDB;

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
  public
    { Public declarations }
  end;

var
  frmMain: TfrmMain;

const
  INI_FILENAME = 'OrganizeItemsThroughBagSync.ini';
  INI_SECTION  = 'Settings';
  INI_KEY      = 'BagSyncPath';

implementation

{$R *.dfm}

function GetIniPath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + INI_FILENAME;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
var
  WoWRoot:     string;
  AccountPath: string;
  FinalPath:   string;
begin
  Edit1.ReadOnly := True;
  Edit1.Color    := clBtnFace;

  PageControl1.ActivePageIndex := 0;

  memoInfo.ReadOnly   := True;
  memoInfo.ScrollBars := ssVertical;

  memoInfo.Lines.Add('Created by Eudoxus/Khadgar-EU, your lovable troll mage ever since late vanilla/early TBC.');
  memoInfo.Lines.Add('');
  memoInfo.Lines.Add('Built for Win 32-bit with Delphi 12 community edition.');
  memoInfo.Lines.Add('Based on the export of the amazing BagSync addon: https://github.com/Xruptor/BagSync');
  memoInfo.Lines.Add('Special thanks to Xruptor for their invaluable contributions to the WoW community.');
  memoInfo.Lines.Add('Using a custom addon (OrganizeItemsThroughBagSyncExport), SQLite v3.51.2 and magic.');
  memoInfo.Lines.Add('Stay away from the Voodoo mon.');
  memoInfo.Lines.Add('');
  memoInfo.Lines.Add('This tool needs your BagSync saved variables file.');
  memoInfo.Lines.Add('');
  memoInfo.Lines.Add('Typical location:');
  memoInfo.Lines.Add('  <WoW install>\World of Warcraft\_retail_\WTF\Account\<AccountName>\SavedVariables\BagSync.lua');
  memoInfo.Lines.Add('');
  memoInfo.Lines.Add('Click "Locate BagSync.lua" to select it manually if auto-detection fails.');
  memoInfo.Lines.Add('');

  // --- Auto-detect WoW install and BagSync.lua path ---
  WoWRoot := GetRetailWoWInstallPath;

  if WoWRoot = '' then
  begin
    memoInfo.Lines.Add('Retail WoW installation could not be found automatically.');
    memoInfo.Lines.Add('Please use "Locate BagSync.lua" to set the path manually.');
    UpdateUIAfterLoad(False);
  end
  else
  begin
    AccountPath := ResolveRetailWoWAccountPathTakeTwo(WoWRoot);

    if AccountPath = '' then
    begin
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
        memoInfo.Lines.Add('Account found, but BagSync.lua is missing at:');
        memoInfo.Lines.Add('  ' + FinalPath);
        UpdateUIAfterLoad(False);
      end;
    end;
  end;

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
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FDatabase.Free;
end;

procedure TfrmMain.FormResize(Sender: TObject);
begin
  ClientWidth  := 925;
  ClientHeight := 750;
end;

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
    Label1.Caption    := 'BagSync.lua ready';
    Label1.Font.Color := clGreen;
    btnLocate.Caption := 'Re-locate / Change / Update';
    btnExecute.Caption := 'Do the magic!';
  end
  else
  begin
    Label1.Caption    := 'BagSync.lua not set';
    Label1.Font.Color := clRed;
    btnLocate.Caption := 'Locate BagSync.lua';
  end;
  btnExecute.Enabled := Success;
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
  memoInfo.Lines.Add('');
  CopyBagSyncToLocal;
  memoInfo.Lines.Add('Parsing: ' + GetLocalBagSyncPath);

  if FileExists(GetLocalBagSyncPath) then
  begin
    try
      ExecuteParsing;
    except
      on E: Exception do
        memoInfo.Lines.Add('Error during parsing: ' + E.Message);
    end;
  end
  else
    memoInfo.Lines.Add('Local file missing after copy attempt.');
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
    memoInfo.Lines.Add('Local BagSync.lua not found.');
    Exit;
  end;

  // Show MD5 + size so we can confirm the right file was copied
  FS := TFileStream.Create(InputFile, fmOpenRead or fmShareDenyNone);
  try
    memoInfo.Lines.Add('MD5 : ' + THashMD5.GetHashString(FS));
    memoInfo.Lines.Add('Size: ' + IntToStr(TFile.GetSize(InputFile)) + ' bytes');
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

      memoInfo.Lines.Add('');
      memoInfo.Lines.Add('=== Import complete ===');
      memoInfo.Lines.Add(Format('Rows:        %d', [Engine.TotalRows]));
      memoInfo.Lines.Add(Format('Unique IDs:  %d', [Engine.UniqueCount]));
      memoInfo.Lines.Add(Format('Total stack: %d', [Engine.TotalStack]));
      memoInfo.Lines.Add('');

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

end.
