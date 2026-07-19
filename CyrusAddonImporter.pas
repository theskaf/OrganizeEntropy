unit CyrusAddonImporter;

//{
//  Responsibility:
//    Parse OrganizeItemsThroughBagSyncExport.lua (the companion addon's
//    SavedVariables file) and emit one TAddonItem record per [itemID] entry
//    found, via anonymous method callback.
//
//  Structure of the file being parsed (depth-2 flat table):
//    OrganizeItemsThroughBagSyncExportDB = {
//      ["items"] = {
//        [106498] = {
//          ["name"]                = "Steamscar Bindings",
//          ["quality"]             = 2,
//          ["item_level"]          = 15,
//          ["min_level"]           = 36,
//          ["item_type"]           = "Armor",
//          ["item_subtype"]        = "Leather",
//          ["max_stack"]           = 1,
//          ["equip_loc"]           = "INVTYPE_WRIST",
//          ["class_id"]            = 4,
//          ["subclass_id"]         = 2,
//          ["bind_type"]           = 2,
//          ["bind_category"]       = "Bind-on-Equip",
//          ["tooltip_bonding"]     = 7,
//          ["expac_id"]            = 5,
//          ["set_id"]              = nil,
//          ["is_crafting_reagent"] = false,
//          ["exported_at"]         = "2026-02-15T06:18:25Z",
//        },
//        ...
//      },
//      ["meta"] = { ... }   -- skipped
//    }
//
//  Uses TCyrusLexer from CyrusParser.pas for tokenization.
//  TCyrusLexer.NextToken returns a TCyrusTokenType.
//  TCyrusLexer.TokenStr holds the string value of the last token.
//}


interface

uses
  System.SysUtils,
  System.Classes,
  CyrusParser;  // TCyrusLexer, TCyrusTokenType

type
  TAddonItem = record
    ItemID            : Integer;
    Name              : string;
    Quality           : Integer;       // Enum.ItemQuality 0-8
    ItemLevel         : Integer;
    MinLevel          : Integer;
    ItemType          : string;
    ItemSubType       : string;
    MaxStack          : Integer;
    EquipLoc          : string;
    ClassID           : Integer;
    SubClassID        : Integer;
    BindType          : Integer;       // Enum.ItemBind 0-4
    BindCategory      : string;        // 'BoP'|'BoE'|'BoU'|'Free'|'Quest'|etc.
    TooltipBonding    : Integer;       // -1 = absent/nil
    ExpacID           : Integer;
    SetID             : Integer;       // -1 = absent/nil
    IsCraftingReagent : Boolean;
    ExportedAt        : string;        // ISO-8601 UTC string
  end;

  TAddonItemFoundEvent = reference to procedure(const Item: TAddonItem);

  TCyrusAddonImporter = class
  private
    FLexer       : TCyrusLexer;
    FCurrentType : TCyrusTokenType;   // result of last NextToken call
    FCallback    : TAddonItemFoundEvent;
    FTotalItems  : Integer;
    FSkipped     : Integer;

    // Advance to next token and store its type
    procedure Advance;

    // Assert current token is AType, then advance; raise on mismatch
    procedure Expect(AType: TCyrusTokenType);

    // Parsing stages
    procedure ParseRoot;
    procedure ParseItemsTable;
    procedure ParseOneItem(AItemID: Integer);

    // Skip helpers
    procedure SkipValue;
    procedure SkipTable;

    // Field value readers
    function ReadStringValue  : string;
    function ReadIntegerValue : Integer;   // 0 if nil/false/absent
    function ReadBoolValue    : Boolean;
    function ReadOptionalInt  : Integer;   // -1 if nil/absent

  public
    constructor Create(const AFileContent: string);
    destructor  Destroy; override;

    // Execute the parse; fires ACallback for each valid item record found.
    procedure Execute(ACallback: TAddonItemFoundEvent);

    property TotalItems : Integer read FTotalItems;
    property Skipped    : Integer read FSkipped;
  end;

implementation

{ TCyrusAddonImporter }

constructor TCyrusAddonImporter.Create(const AFileContent: string);
begin
  inherited Create;
  FLexer       := TCyrusLexer.Create(AFileContent);
  FCurrentType := tkEOF;
  FTotalItems  := 0;
  FSkipped     := 0;
end;

destructor TCyrusAddonImporter.Destroy;
begin
  FLexer.Free;
  inherited;
end;

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

procedure TCyrusAddonImporter.Advance;
begin
  FCurrentType := FLexer.NextToken;
end;

procedure TCyrusAddonImporter.Expect(AType: TCyrusTokenType);
begin
  if FCurrentType <> AType then
    raise Exception.CreateFmt(
      'CyrusAddonImporter: Expected token type %d but got %d (value: "%s")',
      [Ord(AType), Ord(FCurrentType), FLexer.TokenStr]);
  Advance;
end;

// ---------------------------------------------------------------------------
// Root parser
// ---------------------------------------------------------------------------

procedure TCyrusAddonImporter.ParseRoot;
var
  KeyName: string;
begin
  // Scan forward until we find the root identifier
  while FCurrentType <> tkEOF do
  begin
    if (FCurrentType = tkIdentifier) and
       (FLexer.TokenStr = 'OrganizeItemsThroughBagSyncExportDB') then
    begin
      Advance;           // consume identifier
      Expect(tkEqual);   // consume '='
      Expect(tkBraceOpen); // consume '{'

      // Iterate top-level keys: ["items"], ["meta"], etc.
      while (FCurrentType <> tkBraceClose) and (FCurrentType <> tkEOF) do
      begin
        if FCurrentType = tkBracketOpen then
        begin
          Advance; // consume '['
          if FCurrentType = tkString then
          begin
            KeyName := FLexer.TokenStr;
            Advance;              // consume key name
            Expect(tkBracketClose);
            Expect(tkEqual);

            if KeyName = 'items' then
              ParseItemsTable
            else
              SkipValue;          // skip ["meta"] and anything unknown
          end
          else
            SkipValue;
        end
        else
          Advance;

        if FCurrentType = tkComma then
          Advance;
      end;

      if FCurrentType = tkBraceClose then
        Advance; // consume closing '}'

      Exit;
    end;

    Advance;
  end;
end;

// ---------------------------------------------------------------------------
// Items table:  { [106498] = { ... }, [193001] = { ... }, ... }
// ---------------------------------------------------------------------------

procedure TCyrusAddonImporter.ParseItemsTable;
var
  ItemIDStr : string;
  ItemID    : Integer;
begin
  Expect(tkBraceOpen);

  while (FCurrentType <> tkBraceClose) and (FCurrentType <> tkEOF) do
  begin
    if FCurrentType = tkBracketOpen then
    begin
      Advance; // consume '['

      if FCurrentType = tkNumber then
      begin
        ItemIDStr := FLexer.TokenStr;
        Advance;              // consume number
        Expect(tkBracketClose);
        Expect(tkEqual);

        if TryStrToInt(ItemIDStr, ItemID) and (ItemID > 0) then
          ParseOneItem(ItemID)
        else
        begin
          Inc(FSkipped);
          SkipValue;
        end;
      end
      else
      begin
        Inc(FSkipped);
        // consume whatever is inside the brackets then skip the value
        while (FCurrentType <> tkBracketClose) and (FCurrentType <> tkEOF) do
          Advance;
        if FCurrentType = tkBracketClose then Advance;
        if FCurrentType = tkEqual then Advance;
        SkipValue;
      end;
    end
    else
      Advance;

    if FCurrentType = tkComma then
      Advance;
  end;

  Expect(tkBraceClose);
end;

// ---------------------------------------------------------------------------
// Single item:  { ["name"] = "...", ["quality"] = 2, ... }
// ---------------------------------------------------------------------------

procedure TCyrusAddonImporter.ParseOneItem(AItemID: Integer);
var
  Item      : TAddonItem;
  FieldName : string;
begin
  // Defaults
  Item.ItemID            := AItemID;
  Item.Name              := '';
  Item.Quality           := 0;
  Item.ItemLevel         := 0;
  Item.MinLevel          := 0;
  Item.ItemType          := '';
  Item.ItemSubType       := '';
  Item.MaxStack          := 1;
  Item.EquipLoc          := '';
  Item.ClassID           := 0;
  Item.SubClassID        := 0;
  Item.BindType          := 0;
  Item.BindCategory      := 'Free';
  Item.TooltipBonding    := -1;
  Item.ExpacID           := 0;
  Item.SetID             := -1;
  Item.IsCraftingReagent := False;
  Item.ExportedAt        := '';

  Expect(tkBraceOpen);

  while (FCurrentType <> tkBraceClose) and (FCurrentType <> tkEOF) do
  begin
    if FCurrentType = tkBracketOpen then
    begin
      Advance; // consume '['
      if FCurrentType = tkString then
      begin
        FieldName := FLexer.TokenStr;
        Advance;              // consume field name
        Expect(tkBracketClose);
        Expect(tkEqual);

        if      FieldName = 'name'                then Item.Name              := ReadStringValue
        else if FieldName = 'quality'             then Item.Quality           := ReadIntegerValue
        else if FieldName = 'item_level'          then Item.ItemLevel         := ReadIntegerValue
        else if FieldName = 'min_level'           then Item.MinLevel          := ReadIntegerValue
        else if FieldName = 'item_type'           then Item.ItemType          := ReadStringValue
        else if FieldName = 'item_subtype'        then Item.ItemSubType       := ReadStringValue
        else if FieldName = 'max_stack'           then Item.MaxStack          := ReadIntegerValue
        else if FieldName = 'equip_loc'           then Item.EquipLoc          := ReadStringValue
        else if FieldName = 'class_id'            then Item.ClassID           := ReadIntegerValue
        else if FieldName = 'subclass_id'         then Item.SubClassID        := ReadIntegerValue
        else if FieldName = 'bind_type'           then Item.BindType          := ReadIntegerValue
        else if FieldName = 'bind_category'       then Item.BindCategory      := ReadStringValue
        else if FieldName = 'tooltip_bonding'     then Item.TooltipBonding    := ReadOptionalInt
        else if FieldName = 'expac_id'            then Item.ExpacID           := ReadIntegerValue
        else if FieldName = 'set_id'              then Item.SetID             := ReadOptionalInt
        else if FieldName = 'is_crafting_reagent' then Item.IsCraftingReagent := ReadBoolValue
        else if FieldName = 'exported_at'         then Item.ExportedAt        := ReadStringValue
        else
          SkipValue; // ignore: link, bind_text, item_id (redundant)
      end
      else
        SkipValue;
    end
    else
      Advance;

    if FCurrentType = tkComma then
      Advance;
  end;

  Expect(tkBraceClose);

  // Only emit if we got a name (basic sanity check)
  if Item.Name <> '' then
  begin
    Inc(FTotalItems);
    FCallback(Item);
  end
  else
    Inc(FSkipped);
end;

// ---------------------------------------------------------------------------
// Value readers
// ---------------------------------------------------------------------------

function TCyrusAddonImporter.ReadStringValue: string;
begin
  if FCurrentType = tkString then
  begin
    Result := FLexer.TokenStr;
    Advance;
  end
  else
  begin
    Result := '';
    SkipValue;
  end;
end;

function TCyrusAddonImporter.ReadIntegerValue: Integer;
begin
  Result := 0;
  case FCurrentType of
    tkNumber:
      begin
        TryStrToInt(FLexer.TokenStr, Result);
        Advance;
      end;
    tkIdentifier: // nil
      Advance;
    tkFalse:
      begin
        Result := 0;
        Advance;
      end;
    tkTrue:
      begin
        Result := 1;
        Advance;
      end;
  else
    SkipValue;
  end;
end;

function TCyrusAddonImporter.ReadBoolValue: Boolean;
begin
  Result := False;
  case FCurrentType of
    tkTrue:
      begin
        Result := True;
        Advance;
      end;
    tkFalse:
      begin
        Result := False;
        Advance;
      end;
    tkNumber:
      begin
        Result := FLexer.TokenStr <> '0';
        Advance;
      end;
    tkIdentifier: // nil -> false
      Advance;
  else
    SkipValue;
  end;
end;

function TCyrusAddonImporter.ReadOptionalInt: Integer;
begin
  Result := -1;
  case FCurrentType of
    tkNumber:
      begin
        if not TryStrToInt(FLexer.TokenStr, Result) then
          Result := -1;
        Advance;
      end;
    tkIdentifier: // nil
      Advance;
    tkFalse:
      begin
        Result := 0;
        Advance;
      end;
  else
    SkipValue;
  end;
end;

// ---------------------------------------------------------------------------
// Skip helpers
// ---------------------------------------------------------------------------

procedure TCyrusAddonImporter.SkipValue;
begin
  case FCurrentType of
    tkBraceOpen:
      SkipTable;
    tkString, tkNumber, tkTrue, tkFalse:
      Advance;
    tkIdentifier: // nil or unknown
      Advance;
  // Do not advance on structural tokens (braces, brackets) to avoid desync
  end;
end;

procedure TCyrusAddonImporter.SkipTable;
var
  Depth: Integer;
begin
  if FCurrentType <> tkBraceOpen then Exit;
  Depth := 0;
  repeat
    case FCurrentType of
      tkBraceOpen  : Inc(Depth);
      tkBraceClose : Dec(Depth);
      tkEOF        : Break;
    end;
    Advance;
  until Depth = 0;
end;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

procedure TCyrusAddonImporter.Execute(ACallback: TAddonItemFoundEvent);
begin
  if not Assigned(ACallback) then
    raise EArgumentNilException.Create(
      'CyrusAddonImporter.Execute: callback must not be nil');

  FCallback   := ACallback;
  FTotalItems := 0;
  FSkipped    := 0;

  Advance;   // prime the lexer: reads the first token into FCurrentType
  ParseRoot;
end;

end.
