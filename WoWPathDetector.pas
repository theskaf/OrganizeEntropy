unit WoWPathDetector;

interface

uses
  Windows, SysUtils;

function GetRetailWoWInstallPath: string;

implementation

const
  DefaultLocations: array[0..4] of string = (
    'C:\Program Files (x86)\World of Warcraft',
    'D:\World of Warcraft',
    'E:\World of Warcraft',
    'F:\World of Warcraft',
    'C:\Games\World of Warcraft' );


function InternalSearch(const StartDir: string; Depth: Integer; var FoundPath: string): Boolean;
var
  SR: TSearchRec;
  Res: Integer;
  Candidate: string;
begin
  Result := False;
  if Depth > 6 then Exit;
  if not DirectoryExists(StartDir) then Exit;

  Res := FindFirst(StartDir + '.build.info', faAnyFile, SR);
  try
    while Res = 0 do
    begin
      if (SR.Attr and faDirectory = 0) then
      begin
        Candidate := IncludeTrailingPathDelimiter(ExtractFilePath(StartDir + SR.Name));

        if DirectoryExists(Candidate + '_retail_') and
           FileExists(Candidate + '_retail_\Wow.exe') then
        begin
          FoundPath := ExcludeTrailingPathDelimiter(Candidate);
          Result := True;
          Exit;   // found retail WoW
        end;
      end;
      Res := FindNext(SR);
    end;
  finally
    FindClose(SR);
  end;

  Res := FindFirst(StartDir + '*.*', faDirectory, SR);
  try
    while Res = 0 do
    begin
      if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        if InternalSearch(StartDir + SR.Name + '\', Depth + 1, FoundPath) then
        begin
          Result := True;
          Exit;
        end;
      end;
      Res := FindNext(SR);
    end;
  finally
    FindClose(SR);
  end;
end;



function GetRetailWoWInstallPath: string;
var
  Drive: Char;
  StartPath: string;
  i: Integer;
begin
  Result := '';

  for i := Low(DefaultLocations) to High(DefaultLocations) do
  begin
    if DirectoryExists(DefaultLocations[i]) and
       FileExists(DefaultLocations[i] + '\.build.info') and
       DirectoryExists(DefaultLocations[i] + '\_retail_') and
       FileExists(DefaultLocations[i] + '\_retail_\Wow.exe') then
    begin
      Result := DefaultLocations[i];
      Exit;
    end;
  end;

  for Drive := 'C' to 'Z' do
  begin
    StartPath := Drive + ':\';
    if GetDriveType(PChar(StartPath)) = DRIVE_FIXED then
    begin
      if InternalSearch(StartPath, 0, Result) then
        Exit;
    end;
  end;
end;



end.
