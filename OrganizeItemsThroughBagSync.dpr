program OrganizeItemsThroughBagSync;

uses
  Vcl.Forms,
  MainFrm in 'MainFrm.pas' {frmMain},
  CyrusParser in 'CyrusParser.pas',
  CyrusDB in 'CyrusDB.pas',
  WoWPathDetector in 'WoWPathDetector.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
