unit CyrusParser;

{ ============================================================================
  My BagSync PARSER
  ============================================================================

  Schema-Based Emission Rules:
    1. Path must start with "BagSyncDB"
    2. Skip config realms (options§, whitelist§, blacklist§, etc.)
    3. Skip metadata keys (24-key comprehensive list from ParserNew)
    4. Accept ALL non-metadata storage keys (no whitelist)
    5. Detect owner type: © = Guild, § = Warband, else Character
    6. Handle auction's extra "bag" nesting level
    7. Normalize storage names (tabs > guildtab/warbandtab, reagents > reagentbank)
  ============================================================================ }

interface

uses
  System.SysUtils, System.Classes, System.StrUtils,
  System.Generics.Collections;

type
  // =========================================================================
  // Data Record
  // =========================================================================

  TCyrusBagItem = record
    ItemID: string;       // Normalized numeric ID (e.g. "53010")
    ItemString: string;   // Raw item string before normalization (e.g. "53010:0:0:0:0:...")
    OwnerType: string;    // 'Character' | 'Guild' | 'Warband'
    Owner: string;
    Realm: string;
    Storage: string;
    Container: string;
    Count: Int64;
  end;

  // =========================================================================
  // Callback
  // =========================================================================

  TCyrusItemFoundEvent = reference to procedure(const Item: TCyrusBagItem);

  // =========================================================================
  // Lexer (from prev attempt - robust, token-based, no backtracking)
  // =========================================================================

  TCyrusTokenType = (
    tkEOF, tkError, tkIdentifier, tkString, tkNumber,
    tkTrue, tkFalse,
    tkBraceOpen, tkBraceClose,
    tkBracketOpen, tkBracketClose,
    tkEqual, tkComma
  );

  TCyrusLexer = class
  private
    FText: string;
    FPos: Integer;
    FLen: Integer;
    FTokenStr: string;
    procedure SkipWhitespaceAndComments;
  public
    constructor Create(const AText: string);
    function NextToken: TCyrusTokenType;
    property TokenStr: string read FTokenStr;
  end;

  // =========================================================================
  // Engine
  // =========================================================================

  TCyrusEngine = class
  private
    FLexer: TCyrusLexer;
    FCurrentToken: TCyrusTokenType;
    FPath: TList<string>;
    FOnItemFound: TCyrusItemFoundEvent;

    FTotalRows: Integer;
    FTotalStack: Int64;
    FUniqueItems: TDictionary<string, Boolean>;

    function GetUniqueCount: Integer;

    procedure Next;
    procedure ParseTable;
    procedure ParseValue;

    procedure EmitItem(const ItemStr: string);
    procedure NormalizeItem(const ItemStr: string; out AItemID: string; out ACount: Int64);

    function IsMetadataKey(const Key: string): Boolean;
    function GetOwnerType(const Name: string): string;
    function NormalizeStorageType(const Storage: string; const OwnerType: string): string;
    function GetRealmForOwner(const OwnerType, Realm: string): string;
  public
    constructor Create(const AText: string);
    destructor Destroy; override;

    /// <summary>
    /// Runs the full parse. Each discovered item fires ACallback.
    /// </summary>
    procedure Execute(ACallback: TCyrusItemFoundEvent);

    property TotalRows: Integer read FTotalRows;
    property TotalStack: Int64 read FTotalStack;
    property UniqueCount: Integer read GetUniqueCount;
  end;

  // =========================================================================
  // Exporter (from prev architecture)
  // =========================================================================

  TCyrusExporter = class
  private
    FItems: TList<TCyrusBagItem>;
  public
    constructor Create(AItems: TList<TCyrusBagItem>);

    /// <summary>
    /// Exports items to a CSV file at the given path (UTF-8).
    /// </summary>
    procedure ExportToCSV(const AOutputPath: string);
  end;

implementation

{ =========================================================================== }
{ TCyrusLexer                                                                 }
{ =========================================================================== }

constructor TCyrusLexer.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := 1;

  // Handle UTF-8 BOM (Byte Order Mark)
  if (Length(FText) >= 3) and
     (FText[1] = #$EF) and (FText[2] = #$BB) and (FText[3] = #$BF) then
    FPos := 4;

  FLen := Length(FText);
end;

procedure TCyrusLexer.SkipWhitespaceAndComments;
begin
  while FPos <= FLen do
  begin
    // Whitespace
    if CharInSet(FText[FPos], [' ', #9, #10, #13]) then
      Inc(FPos)

    // Single-line comment: --
    else if (FText[FPos] = '-') and (FPos < FLen) and (FText[FPos + 1] = '-') then
    begin
      Inc(FPos, 2);
      while (FPos <= FLen) and not CharInSet(FText[FPos], [#10, #13]) do
        Inc(FPos);
    end

    else
      Break;
  end;
end;

function TCyrusLexer.NextToken: TCyrusTokenType;
var
  StartPos: Integer;
  C: Char;
begin
  SkipWhitespaceAndComments;

  if FPos > FLen then
  begin
    FTokenStr := '';
    Exit(tkEOF);
  end;

  C := FText[FPos];

  case C of
      '{': begin FTokenStr := '{'; Inc(FPos); Exit(tkBraceOpen); end;

      '}': begin FTokenStr := '}'; Inc(FPos); Exit(tkBraceClose); end;

      '[': begin FTokenStr := '['; Inc(FPos); Exit(tkBracketOpen); end;

      ']': begin FTokenStr := ']'; Inc(FPos); Exit(tkBracketClose); end;

      '=': begin FTokenStr := '='; Inc(FPos); Exit(tkEqual); end;

      ',', ';': begin FTokenStr := C; Inc(FPos); Exit(tkComma); end;

      '"', '''': begin
          Inc(FPos);
          StartPos := FPos;

          while (FPos <= FLen) and (FText[FPos] <> C) do
          begin
            if FText[FPos] = '\' then
            begin
              // Bounds-safe escape handling
              if FPos + 1 > FLen then
                raise Exception.CreateFmt(
                  'Unexpected end of input after escape at position %d',
                  [FPos]
                );
              Inc(FPos, 2);
            end
            else
              Inc(FPos);
          end;

          FTokenStr := Copy(FText, StartPos, FPos - StartPos);

          if FPos <= FLen then
            Inc(FPos);  // consume closing quote

          Exit(tkString);
      end;

      else       // Identifiers (including high-byte UTF-8 chars)

      if CharInSet(C, ['a'..'z', 'A'..'Z', '_']) or (Ord(C) > 127) then
      begin
        StartPos := FPos;
        while (FPos <= FLen) and
              not CharInSet(FText[FPos],
                [' ', #9, #10, #13, '=', ',', ';', '{', '}', '[', ']']) do
          Inc(FPos);

        FTokenStr := Copy(FText, StartPos, FPos - StartPos);

        if SameText(FTokenStr, 'true') then Exit(tkTrue);
        if SameText(FTokenStr, 'false') then Exit(tkFalse);
        Exit(tkIdentifier);
      end
      // Numbers
      else if CharInSet(C, ['0'..'9', '-', '+', '.']) then
      begin
        StartPos := FPos;
        while (FPos <= FLen) and
              CharInSet(FText[FPos], ['0'..'9', '.', 'e', 'E', '-', '+']) do
          Inc(FPos);

        FTokenStr := Copy(FText, StartPos, FPos - StartPos);
        Exit(tkNumber);
      end
      else
      begin
        Inc(FPos);
        Exit(tkError);
      end;
  end;
end;

{ =========================================================================== }
{ TCyrusEngine                                                                }
{ =========================================================================== }

constructor TCyrusEngine.Create(const AText: string);
begin
  inherited Create;
  FLexer := TCyrusLexer.Create(AText);
  FPath := TList<string>.Create;
  FUniqueItems := TDictionary<string, Boolean>.Create;
end;

destructor TCyrusEngine.Destroy;
begin
  FUniqueItems.Free;
  FPath.Free;
  FLexer.Free;
  inherited;
end;

procedure TCyrusEngine.Next;
begin
  FCurrentToken := FLexer.NextToken;
end;

function TCyrusEngine.GetUniqueCount: Integer;
begin
  Result := FUniqueItems.Count;
end;

{ --------------------------------------------------------------------------- }
{ Metadata & classification (from prev - comprehensive 24-key list)           }
{ --------------------------------------------------------------------------- }

function TCyrusEngine.IsMetadataKey(const Key: string): Boolean;
begin
  Result :=
    MatchText(Key, [
    'money', 'class', 'race', 'gender', 'faction', 'guild', 'guid',
    'rwsKey', 'realmKey', 'guildrealm', 'professions', 'currency',
    'lastupdate', 'lastscan', 'count', 'name', 'header', 'icon',
    'options§', 'whitelist§', 'blacklist§', 'forceDBReset§',
    'savedsearch§', 'gold'
                    ]);
end;

function TCyrusEngine.GetOwnerType(const Name: string): string;
begin
  if EndsStr('©', Name) then
    Result := 'Guild'
  else if EndsStr('§', Name) then
    Result := 'Warband'
  else if Name <> '' then
    Result := 'Character'
  else
    Result := 'Unknown';
end;

function TCyrusEngine.NormalizeStorageType(const Storage: string; const OwnerType: string): string;
begin
  Result := Storage;
  if SameText(Storage, 'tabs') then
  begin
    if OwnerType = 'Warband' then
      Result := 'warbandtab'
    else
      Result := 'guildtab';
  end
  else if SameText(Storage, 'reagents') then
    Result := 'reagentbank';
end;

function TCyrusEngine.GetRealmForOwner(const OwnerType, Realm: string): string;
begin
  if OwnerType = 'Warband' then
    Result := 'Account'
  else
    Result := Realm;
end;

{ --------------------------------------------------------------------------- }
{ Item ID normalisation                                                        }
{ --------------------------------------------------------------------------- }

procedure TCyrusEngine.NormalizeItem(const ItemStr: string; out AItemID: string; out ACount: Int64);
var
  P: Integer;
  CountStr: string;
  Dummy: Integer;
begin
  ACount := 1;
  AItemID := ItemStr;

  // Split at first semicolon: "itemdata;count"
  P := Pos(';', ItemStr);
  if P > 0 then
  begin
    AItemID := Copy(ItemStr, 1, P - 1);
    CountStr := Copy(ItemStr, P + 1, MaxInt);

    // Count may have further semicolons - take first segment only
    P := Pos(';', CountStr);
    if P > 0 then
      CountStr := Copy(CountStr, 1, P - 1);

    TryStrToInt64(CountStr, ACount);
  end;

  // Strip bonus/enchant suffixes: "12345:0:0:0" -> "12345"
  P := Pos(':', AItemID);
  if P > 0 then
    AItemID := Copy(AItemID, 1, P - 1);

  // Validate: must be a numeric item ID
  if not TryStrToInt(AItemID, Dummy) then
    AItemID := '';
end;

{ --------------------------------------------------------------------------- }
{ Leaf emission                                                                }
{ --------------------------------------------------------------------------- }

procedure TCyrusEngine.EmitItem(const ItemStr: string);
var
  Item: TCyrusBagItem;
  ItemID: string;
  Count: Int64;
  Realm, Owner, Storage, Container, OwnerType: string;
  RawItemString: string;
begin
  // Must be inside BagSyncDB with enough depth.
  // Expected minimum path: [BagSyncDB][Realm][Owner][Storage][Container]
  if FPath.Count < 5 then Exit;
  if FPath[0] <> 'BagSyncDB' then Exit;

  Realm := FPath[1];

  // Skip config sections (treated as metadata realms)
  if IsMetadataKey(Realm) then Exit;

  // ----- Owner --------------------------------------------------------------
  Owner := FPath[2];
  OwnerType := GetOwnerType(Owner);

  // ----- Storage ------------------------------------------------------------
  Storage := FPath[3];

  // Skip metadata storage keys
  if IsMetadataKey(Storage) then Exit;

  // ----- Container ----------------------------------------------------------
  Container := FPath[4];

  // ----- Auction special case: extra "bag" nesting -------------------------
  // Path: [BagSyncDB][Realm][Owner][auction][bag][Container]
  if SameText(Storage, 'auction') and
     SameText(Container, 'bag') and
     (FPath.Count >= 6) then
    Container := FPath[5];

  // ----- Normalize storage name --------------------------------------------
  Storage := NormalizeStorageType(Storage, OwnerType);

  // ----- Capture raw item string BEFORE normalization strips the suffix ----
  // The semicolon-separated count suffix (if any) is dropped here too, so
  // what we store is the item-link part only: e.g. "53010:0:0:0:..." or "53010".
  RawItemString := ItemStr;
  begin
    var P := Pos(';', RawItemString);
    if P > 0 then
      RawItemString := Copy(RawItemString, 1, P - 1);
  end;

  // ----- Normalize item ID & count -----------------------------------------
  NormalizeItem(ItemStr, ItemID, Count);
  if ItemID = '' then Exit;

  // ----- Build record -------------------------------------------------------
  Item.ItemID     := ItemID;
  Item.ItemString := RawItemString;  // raw, with quality/bonus suffix preserved
  Item.OwnerType  := OwnerType;
  Item.Owner      := Owner;
  Item.Realm      := GetRealmForOwner(OwnerType, Realm);
  Item.Storage    := Storage;
  Item.Container  := Container;
  Item.Count      := Count;

  // ----- Stats --------------------------------------------------------------
  Inc(FTotalRows);
  Inc(FTotalStack, Count);
  FUniqueItems.AddOrSetValue(ItemID, True);

  // ----- Emit via callback --------------------------------------------------
  if Assigned(FOnItemFound) then
    FOnItemFound(Item);
end;

{ --------------------------------------------------------------------------- }
{ Recursive-descent parser (no backtracking)                                  }
{ --------------------------------------------------------------------------- }

procedure TCyrusEngine.ParseValue;
begin
  case FCurrentToken of
    tkBraceOpen:
      ParseTable;
    tkString:
      begin
        // Only attempt emission if the last path key is not metadata
        if (FPath.Count > 0) and not IsMetadataKey(FPath.Last) then
          EmitItem(FLexer.TokenStr);
        Next;
      end;
  else
    Next;  // numbers, booleans, etc. - skip
  end;
end;

procedure TCyrusEngine.ParseTable;
var
  ImplicitIdx: Integer;
  Key: string;
  IsExplicit: Boolean;
begin
  Next;  // consume '{'
  ImplicitIdx := 1;

  while (FCurrentToken <> tkBraceClose) and (FCurrentToken <> tkEOF) do
  begin
    IsExplicit := False;

    // Explicit key: ["key"] = ... or [123] = ...
    if FCurrentToken = tkBracketOpen then
    begin
      Next;
      Key := FLexer.TokenStr;
      Next;  // consume key token
      if FCurrentToken = tkBracketClose then Next;
      if FCurrentToken = tkEqual then Next;
      IsExplicit := True;
    end

    // Identifier key: key = ...
    else if FCurrentToken = tkIdentifier then
    begin
      Key := FLexer.TokenStr;
      Next;
      if FCurrentToken = tkEqual then
      begin
        Next;
        IsExplicit := True;
      end;
    end;

    // Implicit (array-style) entry
    if not IsExplicit then
    begin
      Key := IntToStr(ImplicitIdx);
      Inc(ImplicitIdx);
    end;

    FPath.Add(Key);
    ParseValue;
    FPath.Delete(FPath.Count - 1);

    if FCurrentToken = tkComma then
      Next;
  end;

  Next;  // consume '}'
end;

{ --------------------------------------------------------------------------- }
{ Entry point                                                                  }
{ --------------------------------------------------------------------------- }

procedure TCyrusEngine.Execute(ACallback: TCyrusItemFoundEvent);
begin
  FOnItemFound := ACallback;
  FTotalRows   := 0;
  FTotalStack  := 0;
  FUniqueItems.Clear;

  Next;

  // Robust root-level loop: skip stray tokens until we find a variable name
  while FCurrentToken <> tkEOF do
  begin
    if FCurrentToken = tkIdentifier then
    begin
      FPath.Clear;
      FPath.Add(FLexer.TokenStr);
      Next;
      if FCurrentToken = tkEqual then
        Next;
      ParseValue;
    end
    else
      Next;  // skip unexpected tokens between root variables
  end;
end;

{ =========================================================================== }
{ TCyrusExporter                                                              }
{ =========================================================================== }

constructor TCyrusExporter.Create(AItems: TList<TCyrusBagItem>);
begin
  inherited Create;
  if AItems = nil then
    raise EArgumentNilException.Create('Items list cannot be nil');
  FItems := AItems;
end;

procedure TCyrusExporter.ExportToCSV(const AOutputPath: string);
var
  Output: TStringList;
  Item: TCyrusBagItem;
begin
  Output := TStringList.Create;
  try
    // Header
    Output.Add('ItemID,ItemString,OwnerType,Owner,Realm,Storage,Container,Count');

    // Data rows
    for Item in FItems do
    begin
      Output.Add(
        Item.ItemID + ',' +
        Item.ItemString + ',' +
        Item.OwnerType + ',' +
        Item.Owner + ',' +
        Item.Realm + ',' +
        Item.Storage + ',' +
        Item.Container + ',' +
        IntToStr(Item.Count)
      );
    end;

    Output.SaveToFile(AOutputPath, TEncoding.UTF8);
  finally
    Output.Free;
  end;
end;

end.
