unit CyrusDB;

interface

uses
  System.SysUtils, System.Classes,
  Data.DB,
  FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.Stan.Param,
  FireDAC.Phys, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef, FireDAC.Stan.Intf,
  FireDAC.Stan.Option, FireDAC.Stan.Error, FireDAC.DApt, FireDAC.Stan.ExprFuncs,
  FireDAC.VCLUI.Wait, FireDAC.Phys.SQLiteWrapper.Stat,
  System.Generics.Collections, Winapi.Windows;

type
  TCyrusDB = class
  private
    FConnection: TFDConnection;

    FOwnerCache:   TDictionary<string, Integer>;
    FStorageCache: TDictionary<string, Integer>;

    QInsertOwner:     TFDQuery;
    QSelectOwner:     TFDQuery;
    QInsertStorage:   TFDQuery;
    QSelectStorage:   TFDQuery;
    QInsertInventory: TFDQuery;

    QValidationTestONLY: TFDQuery;
    FQUpsertItem:        TFDQuery;

    procedure ConfigureConnection;
    procedure CreateSchema;
  public
    constructor Create;
    destructor Destroy; override;

    procedure InitializeDatabase;

    // ItemString carries the raw BagSync item string (e.g. "53010:0:0:0:...")
    // so that quality/bonus variants are stored as distinct rows.
    procedure InsertInventoryRow(
      const OwnerType, OwnerName, Realm, Storage, Container: string;
      ItemID: Integer;
      Count: Int64;
      const ItemString: string
    );

    // Upsert one item-metadata row from the companion addon export.
    // Pass ATooltipBonding = -1 or ASetID = -1 to store NULL for those fields.
    procedure UpsertItem(
      AItemID             : Integer;
      const AName         : string;
      AQuality            : Integer;
      AItemLevel          : Integer;
      AMinLevel           : Integer;
      const AItemType     : string;
      const AItemSubType  : string;
      AMaxStack           : Integer;
      const AEquipLoc     : string;
      AClassID            : Integer;
      ASubClassID         : Integer;
      ABindType           : Integer;
      const ABindCategory : string;
      ATooltipBonding     : Integer;
      AExpacID            : Integer;
      ASetID              : Integer;
      AIsCraftingReagent  : Boolean;
      const AExportedAt   : string
    );

    property Connection: TFDConnection read FConnection;

    procedure RebuildInventoryStart;
    procedure RebuildInventoryCommit;
    procedure RebuildInventoryRollback;

    procedure GetTableList(AList: TStrings);
    procedure RunValidationTestONLY(const AOutput: TStrings);
    procedure RebuildItemsStart;
    procedure RebuildItemsCommit;
    procedure RebuildItemsRollback;
  end;

implementation

{ =========================================================================== }
{ TCyrusDB                                                                    }
{ =========================================================================== }

constructor TCyrusDB.Create;
begin
  inherited;
  FConnection := TFDConnection.Create(nil);
  ConfigureConnection;

  FOwnerCache   := TDictionary<string, Integer>.Create;
  FStorageCache := TDictionary<string, Integer>.Create;

  // ---- Owners ----
  QInsertOwner := TFDQuery.Create(nil);
  QInsertOwner.Connection := FConnection;
  QInsertOwner.SQL.Text :=
    'INSERT OR IGNORE INTO Owners (OwnerType, OwnerName, Realm) VALUES (?, ?, ?)';
  QInsertOwner.Params[0].DataType := ftString;
  QInsertOwner.Params[1].DataType := ftString;
  QInsertOwner.Params[2].DataType := ftString;

  QSelectOwner := TFDQuery.Create(nil);
  QSelectOwner.Connection := FConnection;
  QSelectOwner.SQL.Text :=
    'SELECT OwnerID FROM Owners WHERE OwnerType = ? AND OwnerName = ? AND Realm = ?';
  QSelectOwner.Params[0].DataType := ftString;
  QSelectOwner.Params[1].DataType := ftString;
  QSelectOwner.Params[2].DataType := ftString;

  // ---- StorageTypes ----
  QInsertStorage := TFDQuery.Create(nil);
  QInsertStorage.Connection := FConnection;
  QInsertStorage.SQL.Text :=
    'INSERT OR IGNORE INTO StorageTypes (StorageName) VALUES (?)';
  QInsertStorage.Params[0].DataType := ftString;

  QSelectStorage := TFDQuery.Create(nil);
  QSelectStorage.Connection := FConnection;
  QSelectStorage.SQL.Text :=
    'SELECT StorageID FROM StorageTypes WHERE StorageName = ?';
  QSelectStorage.Params[0].DataType := ftString;

  // ---- Inventory (Way 3: ItemString is part of UNIQUE key) ----
  // ON CONFLICT target must match the UNIQUE constraint exactly:
  //   (OwnerID, StorageID, Container, ItemID, ItemString)
  // We SUM the count in the unlikely event the same slot+variant appears twice.
  QInsertInventory := TFDQuery.Create(nil);
  QInsertInventory.Connection := FConnection;
  QInsertInventory.SQL.Text :=
    'INSERT INTO Inventory (OwnerID, StorageID, Container, ItemID, ItemString, Count) ' +
    'VALUES (?, ?, ?, ?, ?, ?) ' +
    'ON CONFLICT(OwnerID, StorageID, Container, ItemID, ItemString) ' +
    'DO UPDATE SET Count = Count + excluded.Count;';
  QInsertInventory.Params[0].DataType := ftInteger;   // OwnerID
  QInsertInventory.Params[1].DataType := ftInteger;   // StorageID
  QInsertInventory.Params[2].DataType := ftString;    // Container
  QInsertInventory.Params[3].DataType := ftInteger;   // ItemID
  QInsertInventory.Params[4].DataType := ftString;    // ItemString
  QInsertInventory.Params[5].DataType := ftLargeint;  // Count

  // ---- Validation query ----
  QValidationTestONLY := TFDQuery.Create(nil);
  QValidationTestONLY.Connection := FConnection;
  QValidationTestONLY.SQL.Text :=
    'SELECT ' +
    '  o.OwnerName, ' +
    '  o.Realm, ' +
    '  s.StorageName, ' +
    '  i.Container, ' +
    '  i.ItemID, ' +
    '  i.ItemString, ' +
    '  i.Count ' +
    'FROM Inventory i ' +
    'JOIN Owners o ON i.OwnerID = o.OwnerID ' +
    'JOIN StorageTypes s ON i.StorageID = s.StorageID ' +
    'ORDER BY o.OwnerName, s.StorageName;';

  // ---- Items upsert (companion addon import) ----
  // ON CONFLICT(ItemID) updates all fields, but only when the incoming
  // ExportedAt timestamp is >= the stored LastSeenUTC, so a stale re-run
  // cannot overwrite a newer export.
  FQUpsertItem := TFDQuery.Create(nil);
  FQUpsertItem.Connection := FConnection;
  FQUpsertItem.SQL.Text :=
    'INSERT INTO Items ' +
    '  (ItemID, Name, Quality, ItemLevel, MinLevel, ItemType, ItemSubType, ' +
    '   MaxStack, EquipLoc, ClassID, SubClassID, BindType, BindCategory, ' +
    '   TooltipBonding, ExpacID, SetID, IsCraftingReagent, ' +
    '   FirstSeenUTC, LastSeenUTC) ' +
    'VALUES ' +
    '  (:ItemID, :Name, :Quality, :ItemLevel, :MinLevel, :ItemType, :ItemSubType, ' +
    '   :MaxStack, :EquipLoc, :ClassID, :SubClassID, :BindType, :BindCategory, ' +
    '   :TooltipBonding, :ExpacID, :SetID, :IsCraftingReagent, ' +
    '   :ExportedAt, :ExportedAt) ' +
    'ON CONFLICT(ItemID) DO UPDATE SET ' +
    '  Name              = excluded.Name, ' +
    '  Quality           = excluded.Quality, ' +
    '  ItemLevel         = excluded.ItemLevel, ' +
    '  MinLevel          = excluded.MinLevel, ' +
    '  ItemType          = excluded.ItemType, ' +
    '  ItemSubType       = excluded.ItemSubType, ' +
    '  MaxStack          = excluded.MaxStack, ' +
    '  EquipLoc          = excluded.EquipLoc, ' +
    '  ClassID           = excluded.ClassID, ' +
    '  SubClassID        = excluded.SubClassID, ' +
    '  BindType          = excluded.BindType, ' +
    '  BindCategory      = excluded.BindCategory, ' +
    '  TooltipBonding    = excluded.TooltipBonding, ' +
    '  ExpacID           = excluded.ExpacID, ' +
    '  SetID             = excluded.SetID, ' +
    '  IsCraftingReagent = excluded.IsCraftingReagent, ' +
    '  LastSeenUTC       = excluded.LastSeenUTC ' +
    'WHERE excluded.LastSeenUTC >= Items.LastSeenUTC;';

  // Declare parameter types so FireDAC can prepare without needing values first
  FQUpsertItem.ParamByName('ItemID').DataType            := ftInteger;
  FQUpsertItem.ParamByName('Name').DataType              := ftString;
  FQUpsertItem.ParamByName('Quality').DataType           := ftInteger;
  FQUpsertItem.ParamByName('ItemLevel').DataType         := ftInteger;
  FQUpsertItem.ParamByName('MinLevel').DataType          := ftInteger;
  FQUpsertItem.ParamByName('ItemType').DataType          := ftString;
  FQUpsertItem.ParamByName('ItemSubType').DataType       := ftString;
  FQUpsertItem.ParamByName('MaxStack').DataType          := ftInteger;
  FQUpsertItem.ParamByName('EquipLoc').DataType          := ftString;
  FQUpsertItem.ParamByName('ClassID').DataType           := ftInteger;
  FQUpsertItem.ParamByName('SubClassID').DataType        := ftInteger;
  FQUpsertItem.ParamByName('BindType').DataType          := ftInteger;
  FQUpsertItem.ParamByName('BindCategory').DataType      := ftString;
  FQUpsertItem.ParamByName('TooltipBonding').DataType    := ftInteger;
  FQUpsertItem.ParamByName('ExpacID').DataType           := ftInteger;
  FQUpsertItem.ParamByName('SetID').DataType             := ftInteger;
  FQUpsertItem.ParamByName('IsCraftingReagent').DataType := ftInteger;
  FQUpsertItem.ParamByName('ExportedAt').DataType        := ftString;
end;

destructor TCyrusDB.Destroy;
begin
  QValidationTestONLY.Free;
  FQUpsertItem.Free;
  QInsertOwner.Free;
  QSelectOwner.Free;
  QInsertStorage.Free;
  QSelectStorage.Free;
  QInsertInventory.Free;
  FOwnerCache.Free;
  FStorageCache.Free;
  if FConnection.Connected then
    FConnection.Close;
  FConnection.Free;
  inherited;
end;

procedure TCyrusDB.ConfigureConnection;
begin
  FConnection.DriverName := 'SQLite';
  FConnection.Params.Add('OpenMode=CreateUTF8');
  FConnection.Params.Add('LockingMode=Normal');
  FConnection.Params.Add('Synchronous=Normal');
  FConnection.UpdateOptions.CountUpdatedRecords := False;
  FConnection.ResourceOptions.SilentMode := True;
  FConnection.Params.Database := ExtractFilePath(ParamStr(0)) + 'OrganizeEntropy.db';
  FConnection.LoginPrompt := False;
end;

procedure TCyrusDB.CreateSchema;
begin
  FConnection.ExecSQL('PRAGMA journal_mode = WAL;');
  FConnection.ExecSQL('PRAGMA foreign_keys = ON;');

  FConnection.ExecSQL(
    'CREATE TABLE IF NOT EXISTS Owners (' +
    '  OwnerID   INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  OwnerType TEXT    NOT NULL,' +
    '  OwnerName TEXT    NOT NULL,' +
    '  Realm     TEXT    NOT NULL,' +
    '  UNIQUE(OwnerType, OwnerName, Realm)' +
    ');'
  );

  FConnection.ExecSQL(
    'CREATE TABLE IF NOT EXISTS StorageTypes (' +
    '  StorageID   INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  StorageName TEXT    NOT NULL UNIQUE' +
    ');'
  );

  // Way 3: ItemString is stored raw so quality/bonus variants become distinct
  // rows.  The UNIQUE constraint now includes ItemString so e.g.
  // "210933:0:0:0:0:0:0:0:0:0:0:0:0:0:10223:..." (Quality 1 Aqirite) and
  // "210933:0:0:0:0:0:0:0:0:0:0:0:0:0:10224:..." (Quality 2) are kept
  // separate instead of being summed into one row.
  FConnection.ExecSQL(
    'CREATE TABLE IF NOT EXISTS Inventory (' +
    '  InventoryID INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  OwnerID     INTEGER NOT NULL,' +
    '  StorageID   INTEGER NOT NULL,' +
    '  Container   TEXT    NOT NULL,' +
    '  ItemID      INTEGER NOT NULL,' +
    '  ItemString  TEXT    NOT NULL DEFAULT '''',' +
    '  Count       INTEGER NOT NULL,' +
    '  FOREIGN KEY (OwnerID)   REFERENCES Owners(OwnerID)       ON DELETE RESTRICT,' +
    '  FOREIGN KEY (StorageID) REFERENCES StorageTypes(StorageID) ON DELETE RESTRICT,' +
    '  UNIQUE(OwnerID, StorageID, Container, ItemID, ItemString)' +
    ');'
  );

  FConnection.ExecSQL(
    'CREATE INDEX IF NOT EXISTS IDX_Inventory_ItemID ON Inventory(ItemID);'
  );

  FConnection.ExecSQL(
    'CREATE TABLE IF NOT EXISTS Items (' +
    '  ItemID             INTEGER PRIMARY KEY,' +
    '  Name               TEXT,' +
    '  Quality            INTEGER,' +
    '  ItemLevel          INTEGER,' +
    '  MinLevel           INTEGER,' +
    '  ItemType           TEXT,' +
    '  ItemSubType        TEXT,' +
    '  MaxStack           INTEGER,' +
    '  EquipLoc           TEXT,' +
    '  ClassID            INTEGER,' +
    '  SubClassID         INTEGER,' +
    '  BindType           INTEGER,' +
    '  BindCategory       TEXT,' +
    '  TooltipBonding     INTEGER,' +
    '  ExpacID            INTEGER,' +
    '  SetID              INTEGER,' +
    '  IsCraftingReagent  INTEGER,' +
    '  FirstSeenUTC       TEXT,' +
    '  LastSeenUTC        TEXT' +
    ');'
  );

  FConnection.ExecSQL(
    'CREATE INDEX IF NOT EXISTS IDX_Items_BindCategory ON Items(BindCategory);'
  );
end;

procedure TCyrusDB.InitializeDatabase;
var
  TempList: TStringList;
begin
  try
    FConnection.Connected := True;
  except
    on E: Exception do
    begin
      OutputDebugString(PChar('Connection failed: ' + E.Message));
      raise;
    end;
  end;

  try
    CreateSchema;
  except
    on E: Exception do
    begin
      OutputDebugString(PChar('CreateSchema failed: ' + E.Message));
      raise;
    end;
  end;

  // Prepare all statements after the schema exists
  QInsertOwner.Prepare;
  QSelectOwner.Prepare;
  QInsertStorage.Prepare;
  QSelectStorage.Prepare;
  QInsertInventory.Prepare;
  QValidationTestONLY.Prepare;
  FQUpsertItem.Prepare;

  TempList := TStringList.Create;
  try
    GetTableList(TempList);
    OutputDebugString(PChar('Schema ready. Tables: ' + TempList.CommaText));
  finally
    TempList.Free;
  end;
end;

procedure TCyrusDB.InsertInventoryRow(
  const OwnerType, OwnerName, Realm, Storage, Container: string;
  ItemID: Integer;
  Count: Int64;
  const ItemString: string
);
var
  OwnerKey:  string;
  OwnerID:   Integer;
  StorageID: Integer;
begin
  if ItemID <= 0 then
    Exit;

  // ---------- OWNER (cached) ----------
  OwnerKey := OwnerType + '|' + OwnerName + '|' + Realm;

  if not FOwnerCache.TryGetValue(OwnerKey, OwnerID) then
  begin
    QInsertOwner.Params[0].AsString := OwnerType;
    QInsertOwner.Params[1].AsString := OwnerName;
    QInsertOwner.Params[2].AsString := Realm;
    QInsertOwner.ExecSQL;

    QSelectOwner.Params[0].AsString := OwnerType;
    QSelectOwner.Params[1].AsString := OwnerName;
    QSelectOwner.Params[2].AsString := Realm;
    QSelectOwner.Open;
    OwnerID := QSelectOwner.Fields[0].AsInteger;
    QSelectOwner.Close;

    FOwnerCache.Add(OwnerKey, OwnerID);
  end;

  // ---------- STORAGE (cached) ----------
  if not FStorageCache.TryGetValue(Storage, StorageID) then
  begin
    QInsertStorage.Params[0].AsString := Storage;
    QInsertStorage.ExecSQL;

    QSelectStorage.Params[0].AsString := Storage;
    QSelectStorage.Open;
    StorageID := QSelectStorage.Fields[0].AsInteger;
    QSelectStorage.Close;

    FStorageCache.Add(Storage, StorageID);
  end;

  // ---------- INVENTORY ----------
  QInsertInventory.Params[0].AsInteger  := OwnerID;
  QInsertInventory.Params[1].AsInteger  := StorageID;
  QInsertInventory.Params[2].AsString   := Container;
  QInsertInventory.Params[3].AsInteger  := ItemID;
  QInsertInventory.Params[4].AsString   := ItemString;
  QInsertInventory.Params[5].AsLargeInt := Count;
  QInsertInventory.ExecSQL;
end;

procedure TCyrusDB.UpsertItem(
  AItemID             : Integer;
  const AName         : string;
  AQuality            : Integer;
  AItemLevel          : Integer;
  AMinLevel           : Integer;
  const AItemType     : string;
  const AItemSubType  : string;
  AMaxStack           : Integer;
  const AEquipLoc     : string;
  AClassID            : Integer;
  ASubClassID         : Integer;
  ABindType           : Integer;
  const ABindCategory : string;
  ATooltipBonding     : Integer;
  AExpacID            : Integer;
  ASetID              : Integer;
  AIsCraftingReagent  : Boolean;
  const AExportedAt   : string
);
begin
  if AItemID <= 0 then
    Exit;

  FQUpsertItem.ParamByName('ItemID').AsInteger            := AItemID;
  FQUpsertItem.ParamByName('Name').AsString               := AName;
  FQUpsertItem.ParamByName('Quality').AsInteger           := AQuality;
  FQUpsertItem.ParamByName('ItemLevel').AsInteger         := AItemLevel;
  FQUpsertItem.ParamByName('MinLevel').AsInteger          := AMinLevel;
  FQUpsertItem.ParamByName('ItemType').AsString           := AItemType;
  FQUpsertItem.ParamByName('ItemSubType').AsString        := AItemSubType;
  FQUpsertItem.ParamByName('MaxStack').AsInteger          := AMaxStack;
  FQUpsertItem.ParamByName('EquipLoc').AsString           := AEquipLoc;
  FQUpsertItem.ParamByName('ClassID').AsInteger           := AClassID;
  FQUpsertItem.ParamByName('SubClassID').AsInteger        := ASubClassID;
  FQUpsertItem.ParamByName('BindType').AsInteger          := ABindType;
  FQUpsertItem.ParamByName('BindCategory').AsString       := ABindCategory;
  FQUpsertItem.ParamByName('ExpacID').AsInteger           := AExpacID;
  FQUpsertItem.ParamByName('IsCraftingReagent').AsInteger := Ord(AIsCraftingReagent);
  FQUpsertItem.ParamByName('ExportedAt').AsString         := AExportedAt;

  // NULL-able fields: -1 sentinel -> stored as NULL
  if ATooltipBonding = -1 then
    FQUpsertItem.ParamByName('TooltipBonding').Clear
  else
    FQUpsertItem.ParamByName('TooltipBonding').AsInteger := ATooltipBonding;

  if ASetID = -1 then
    FQUpsertItem.ParamByName('SetID').Clear
  else
    FQUpsertItem.ParamByName('SetID').AsInteger := ASetID;

  FQUpsertItem.ExecSQL;
end;

procedure TCyrusDB.RebuildInventoryStart;
begin
  FConnection.StartTransaction;
  FConnection.ExecSQL('DELETE FROM Inventory;');
  FOwnerCache.Clear;
  FStorageCache.Clear;
end;

procedure TCyrusDB.RebuildItemsCommit;
begin
  FConnection.Commit;
end;

procedure TCyrusDB.RebuildItemsRollback;
begin
  if FConnection.InTransaction then
    FConnection.Rollback;
end;

procedure TCyrusDB.RebuildItemsStart;
begin
  // Does NOT delete existing rows — Items is additive/upsert only
  // But we do wrap in a transaction for performance
  FConnection.StartTransaction;
end;

procedure TCyrusDB.RebuildInventoryCommit;
begin
  FConnection.Commit;
end;

procedure TCyrusDB.RebuildInventoryRollback;
begin
  if FConnection.InTransaction then
    FConnection.Rollback;
end;

procedure TCyrusDB.GetTableList(AList: TStrings);
var
  Qry: TFDQuery;
begin
  AList.BeginUpdate;
  try
    AList.Clear;
    Qry := TFDQuery.Create(nil);
    try
      Qry.Connection := FConnection;
      Qry.SQL.Text :=
        'SELECT name FROM sqlite_master ' +
        'WHERE type = ''table'' AND name NOT LIKE ''sqlite_%'' ' +
        'ORDER BY name;';
      Qry.Open;
      while not Qry.Eof do
      begin
        AList.Add(Qry.FieldByName('name').AsString);
        Qry.Next;
      end;
      Qry.Close;
    finally
      Qry.Free;
    end;
  finally
    AList.EndUpdate;
  end;
end;

procedure TCyrusDB.RunValidationTestONLY(const AOutput: TStrings);
var
  Qry: TFDQuery;
begin
  // --- Part 1: full inventory dump ---
  QValidationTestONLY.Open;
  try
    while not QValidationTestONLY.Eof do
    begin
      AOutput.Add(
        Format('%s | %s | %s | %s | %d | %s | %d',
        [
          QValidationTestONLY.Fields[0].AsString,  // OwnerName
          QValidationTestONLY.Fields[1].AsString,  // Realm
          QValidationTestONLY.Fields[2].AsString,  // StorageName
          QValidationTestONLY.Fields[3].AsString,  // Container
          QValidationTestONLY.Fields[4].AsInteger, // ItemID
          QValidationTestONLY.Fields[5].AsString,  // ItemString
          QValidationTestONLY.Fields[6].AsLargeInt // Count
        ])
      );
      QValidationTestONLY.Next;
    end;
  finally
    QValidationTestONLY.Close;
  end;

  // --- Part 2: Items table coverage summary ---
  AOutput.Add('');
  AOutput.Add('=== Items Coverage ===');
  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := FConnection;
    Qry.SQL.Text :=
      'SELECT ' +
      '  COUNT(DISTINCT i.ItemID) AS TotalInventoryIDs, ' +
      '  COUNT(DISTINCT CASE WHEN it.ItemID IS NOT NULL THEN i.ItemID END) AS CoveredByItems, ' +
      '  COUNT(DISTINCT CASE WHEN it.ItemID IS NULL THEN i.ItemID END) AS StillMissing ' +
      'FROM Inventory i ' +
      'LEFT JOIN Items it ON it.ItemID = i.ItemID;';
    Qry.Open;
    if not Qry.Eof then
      AOutput.Add(Format(
        'Total distinct ItemIDs in Inventory : %d' + sLineBreak +
        'Covered by Items table              : %d' + sLineBreak +
        'Still missing from Items table      : %d',
        [
          Qry.FieldByName('TotalInventoryIDs').AsInteger,
          Qry.FieldByName('CoveredByItems').AsInteger,
          Qry.FieldByName('StillMissing').AsInteger
        ]));
    Qry.Close;
  finally
    Qry.Free;
  end;
end;

end.
