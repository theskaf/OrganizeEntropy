unit CyrusConsolidator;

{ ============================================================================
  Consolidation query engine (Milestone C).

  UI-agnostic: given a set of participating OwnerIDs, it inspects the Inventory
  and Items tables and reports, per item variant (ItemID + raw ItemString), how
  many bag/bank/tab slots could be freed by merging partial stacks.

  Two notions of "moveable":
    - Freely moveable (BindType 0/None, 2/BoE, 3/BoU, or unknown/-1):
      stacks can be merged across owners, so the minimum slot count is
      Ceil(TotalCount / MaxStack) over the whole selection.
    - Bound (BindType 1/BoP, 4/Quest):
      stacks can only be merged within the SAME owner, so the minimum slot
      count is summed per owner.

  Only variants where SlotsSaveable > 0 are returned.
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.Math,
  Data.DB, FireDAC.Comp.Client;

type
  TConsolidationResult = record
    ItemID         : Integer;
    ItemString     : string;   // raw variant key (quality/bonus preserved)
    Name           : string;
    Quality        : Integer;  // -1 when metadata missing
    BindType       : Integer;  // -1 when metadata missing
    BindCategory   : string;   // addon classification (Warbound/Account-Bound/BoP/...)
    MaxStack       : Integer;  // effective (>= 1)
    OwnerCount     : Integer;  // distinct owners holding this variant
    StackCount     : Integer;  // current inventory rows (occupied slots)
    TotalCount     : Int64;    // total quantity across the selection
    MinSlotsNeeded : Integer;
    SlotsSaveable  : Integer;
    MetadataKnown  : Boolean;  // False when no matching Items row
    FreelyMoveable : Boolean;  // True if movable among your OWN characters
  end;

  TItemLocation = record
    OwnerID     : Integer;
    OwnerType   : string;
    OwnerName   : string;
    Realm       : string;
    StorageName : string;
    Container   : string;
    Count       : Int64;
  end;

  TCyrusConsolidator = class
  private
    FConnection: TFDConnection;
    class function OwnerIDsToInClause(const AOwnerIDs: TArray<Integer>): string; static;
    class function IsMoveable(const ACategory: string; ABindType: Integer): Boolean; static;
  public
    constructor Create(AConnection: TFDConnection);

    /// <summary>
    /// Computes consolidation opportunities across the given owners.
    /// Returns a list ordered by SlotsSaveable descending (caller owns it).
    /// An empty selection yields an empty list.
    /// </summary>
    function RunConsolidation(const AOwnerIDs: TArray<Integer>): TList<TConsolidationResult>;

    /// <summary>
    /// Every slot (owner/storage/container) holding the given item variant,
    /// restricted to the selected owners, ordered by Count descending.
    /// </summary>
    function GetItemLocations(AItemID: Integer; const AItemString: string;
      const AOwnerIDs: TArray<Integer>): TList<TItemLocation>;
  end;

implementation

{ ---------------------------------------------------------------------------
  Internal per-owner accumulator used while folding the SQL result set.
  --------------------------------------------------------------------------- }
type
  TVariantAccum = class
    ItemID        : Integer;
    ItemString    : string;
    Name          : string;
    Quality       : Integer;
    BindType      : Integer;
    BindCategory  : string;
    MaxStack      : Integer;
    MetadataKnown : Boolean;
    OwnerCount    : Integer;
    StackCount    : Integer;
    TotalCount    : Int64;
    BoundMinSlots : Integer;   // running sum of per-owner Ceil(ownerTotal/MaxStack)
  end;

{ TCyrusConsolidator }

constructor TCyrusConsolidator.Create(AConnection: TFDConnection);
begin
  inherited Create;
  FConnection := AConnection;
end;

class function TCyrusConsolidator.IsMoveable(const ACategory: string; ABindType: Integer): Boolean;
var
  C: string;
begin
  // "Moveable" here means it can be shifted between the user's OWN characters.
  // Warband-bound and Account-bound items qualify (they travel via the Warband
  // bank or mail among your own characters), even though they are "bound".
  C := LowerCase(Trim(ACategory));
  if (C = 'bind-on-pickup') or (C = 'quest-item') or (C = 'soulbound') then
    Exit(False);
  if (C = 'tradeable') or (C = 'bind-on-equip') or (C = 'bind-on-use') or
     (C = 'warbound') or (C = 'warbound-boe') or (C = 'account-bound') then
    Exit(True);
  // Unknown/empty classification -> fall back to the numeric bind type:
  // None (0), BoE (2), BoU (3) movable; BoP (1), Quest (4) bound.
  Result := (ABindType <> 1) and (ABindType <> 4);
end;

class function TCyrusConsolidator.OwnerIDsToInClause(const AOwnerIDs: TArray<Integer>): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  // AOwnerIDs are integers, so simple comma-join is injection-safe.
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(AOwnerIDs) do
    begin
      if I > 0 then
        SB.Append(',');
      SB.Append(AOwnerIDs[I]);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TCyrusConsolidator.RunConsolidation(
  const AOwnerIDs: TArray<Integer>): TList<TConsolidationResult>;
var
  Qry     : TFDQuery;
  InClause: string;
  Map     : TObjectDictionary<string, TVariantAccum>;
  Key     : string;
  Acc     : TVariantAccum;
  EffMax  : Integer;
  OwnerTot: Int64;
  OwnerStk: Integer;
  R       : TConsolidationResult;
begin
  Result := TList<TConsolidationResult>.Create;

  if Length(AOwnerIDs) = 0 then
    Exit;

  InClause := OwnerIDsToInClause(AOwnerIDs);

  Map := TObjectDictionary<string, TVariantAccum>.Create([doOwnsValues]);
  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := FConnection;
    Qry.SQL.Text :=
      'SELECT ' +
      '  i.ItemID                       AS ItemID, ' +
      '  i.ItemString                   AS ItemString, ' +
      '  i.OwnerID                      AS OwnerID, ' +
      '  COUNT(*)                       AS OwnerStacks, ' +
      '  SUM(i.Count)                   AS OwnerTotal, ' +
      '  COALESCE(it.Name, '''')          AS Name, ' +
      '  COALESCE(it.Quality, -1)       AS Quality, ' +
      '  COALESCE(it.BindType, -1)      AS BindType, ' +
      '  COALESCE(it.BindCategory, '''') AS BindCategory, ' +
      '  COALESCE(it.MaxStack, 0)       AS MaxStack, ' +
      '  CASE WHEN it.ItemID IS NULL THEN 0 ELSE 1 END AS HasMeta ' +
      'FROM Inventory i ' +
      'LEFT JOIN Items it ON it.ItemID = i.ItemID ' +
      'WHERE i.OwnerID IN (' + InClause + ') ' +
      'GROUP BY i.ItemID, i.ItemString, i.OwnerID;';
    Qry.Open;

    while not Qry.Eof do
    begin
      Key := Qry.FieldByName('ItemID').AsString + '|' + Qry.FieldByName('ItemString').AsString;

      EffMax := Qry.FieldByName('MaxStack').AsInteger;
      if EffMax < 1 then
        EffMax := 1;

      OwnerStk := Qry.FieldByName('OwnerStacks').AsInteger;
      OwnerTot := Qry.FieldByName('OwnerTotal').AsLargeInt;

      if not Map.TryGetValue(Key, Acc) then
      begin
        Acc := TVariantAccum.Create;
        Acc.ItemID        := Qry.FieldByName('ItemID').AsInteger;
        Acc.ItemString    := Qry.FieldByName('ItemString').AsString;
        Acc.Name          := Qry.FieldByName('Name').AsString;
        Acc.Quality       := Qry.FieldByName('Quality').AsInteger;
        Acc.BindType      := Qry.FieldByName('BindType').AsInteger;
        Acc.BindCategory  := Qry.FieldByName('BindCategory').AsString;
        Acc.MaxStack      := EffMax;
        Acc.MetadataKnown := Qry.FieldByName('HasMeta').AsInteger = 1;
        Acc.OwnerCount    := 0;
        Acc.StackCount    := 0;
        Acc.TotalCount    := 0;
        Acc.BoundMinSlots := 0;
        Map.Add(Key, Acc);
      end;

      Inc(Acc.OwnerCount);
      Inc(Acc.StackCount, OwnerStk);
      Inc(Acc.TotalCount, OwnerTot);
      // per-owner minimum for the "bound" case
      Inc(Acc.BoundMinSlots, Ceil(OwnerTot / Acc.MaxStack));

      Qry.Next;
    end;
    Qry.Close;

    // Fold accumulators into results, keeping only genuine savings.
    for Acc in Map.Values do
    begin
      R := Default(TConsolidationResult);
      R.ItemID         := Acc.ItemID;
      R.ItemString     := Acc.ItemString;
      R.Name           := Acc.Name;
      R.Quality        := Acc.Quality;
      R.BindType       := Acc.BindType;
      R.BindCategory   := Acc.BindCategory;
      R.MaxStack       := Acc.MaxStack;
      R.OwnerCount     := Acc.OwnerCount;
      R.StackCount     := Acc.StackCount;
      R.TotalCount     := Acc.TotalCount;
      R.MetadataKnown  := Acc.MetadataKnown;
      R.FreelyMoveable := IsMoveable(Acc.BindCategory, Acc.BindType);

      if R.FreelyMoveable then
        R.MinSlotsNeeded := Ceil(Acc.TotalCount / Acc.MaxStack)
      else
        R.MinSlotsNeeded := Acc.BoundMinSlots;

      R.SlotsSaveable := Acc.StackCount - R.MinSlotsNeeded;

      if R.SlotsSaveable > 0 then
        Result.Add(R);
    end;
  finally
    Qry.Free;
    Map.Free;
  end;

  Result.Sort(TComparer<TConsolidationResult>.Construct(
    function(const A, B: TConsolidationResult): Integer
    begin
      // SlotsSaveable desc, then TotalCount desc, then Name asc
      Result := B.SlotsSaveable - A.SlotsSaveable;
      if Result = 0 then
        Result := CompareValue(B.TotalCount, A.TotalCount);
      if Result = 0 then
        Result := CompareText(A.Name, B.Name);
    end));
end;

function TCyrusConsolidator.GetItemLocations(AItemID: Integer;
  const AItemString: string; const AOwnerIDs: TArray<Integer>): TList<TItemLocation>;
var
  Qry     : TFDQuery;
  InClause: string;
  Loc     : TItemLocation;
begin
  Result := TList<TItemLocation>.Create;

  if Length(AOwnerIDs) = 0 then
    Exit;

  InClause := OwnerIDsToInClause(AOwnerIDs);

  Qry := TFDQuery.Create(nil);
  try
    Qry.Connection := FConnection;
    Qry.SQL.Text :=
      'SELECT ' +
      '  o.OwnerID, o.OwnerType, o.OwnerName, o.Realm, ' +
      '  s.StorageName, i.Container, i.Count ' +
      'FROM Inventory i ' +
      'JOIN Owners o        ON o.OwnerID   = i.OwnerID ' +
      'JOIN StorageTypes s  ON s.StorageID = i.StorageID ' +
      'WHERE i.ItemID = :ItemID ' +
      '  AND i.ItemString = :ItemString ' +
      '  AND i.OwnerID IN (' + InClause + ') ' +
      'ORDER BY i.Count DESC;';
    Qry.ParamByName('ItemID').AsInteger    := AItemID;
    Qry.ParamByName('ItemString').AsString := AItemString;
    Qry.Open;

    while not Qry.Eof do
    begin
      Loc.OwnerID     := Qry.FieldByName('OwnerID').AsInteger;
      Loc.OwnerType   := Qry.FieldByName('OwnerType').AsString;
      Loc.OwnerName   := Qry.FieldByName('OwnerName').AsString;
      Loc.Realm       := Qry.FieldByName('Realm').AsString;
      Loc.StorageName := Qry.FieldByName('StorageName').AsString;
      Loc.Container   := Qry.FieldByName('Container').AsString;
      Loc.Count       := Qry.FieldByName('Count').AsLargeInt;
      Result.Add(Loc);
      Qry.Next;
    end;
    Qry.Close;
  finally
    Qry.Free;
  end;
end;

end.
