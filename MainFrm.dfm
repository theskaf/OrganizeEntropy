object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Organize Items Using BagSync addon'
  ClientHeight = 750
  ClientWidth = 925
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnResize = FormResize
  TextHeight = 15
  object PageControl1: TPageControl
    Left = 0
    Top = 0
    Width = 925
    Height = 750
    ActivePage = TabSheet1
    Align = alClient
    TabOrder = 0
    ExplicitWidth = 923
    ExplicitHeight = 742
    object TabSheet1: TTabSheet
      Caption = '   Main   '
      object Panel1: TPanel
        Left = 0
        Top = 0
        Width = 917
        Height = 457
        Align = alTop
        TabOrder = 0
        object Label1: TLabel
          Left = 13
          Top = 331
          Width = 134
          Height = 23
          Caption = 'BagSync.lua Path:'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -17
          Font.Name = 'Segoe UI'
          Font.Style = []
          ParentFont = False
        end
        object Edit1: TEdit
          Left = 6
          Top = 383
          Width = 905
          Height = 23
          TabOrder = 0
        end
        object btnLocate: TButton
          Left = 6
          Top = 417
          Width = 249
          Height = 25
          Caption = 'btnLocate'
          TabOrder = 1
          OnClick = btnLocateClick
        end
        object btnExecute: TButton
          Left = 340
          Top = 417
          Width = 249
          Height = 25
          Caption = '*'
          TabOrder = 2
          OnClick = btnExecuteClick
        end
        object memoInfo: TMemo
          Left = 1
          Top = 1
          Width = 915
          Height = 304
          Align = alTop
          ScrollBars = ssBoth
          TabOrder = 3
        end
        object btnImportItems: TButton
          Left = 662
          Top = 417
          Width = 249
          Height = 25
          Caption = 'Import Item Data'
          TabOrder = 4
          OnClick = btnImportItemsClick
        end
      end
      object StringGrid1: TStringGrid
        Left = 0
        Top = 457
        Width = 917
        Height = 263
        Align = alClient
        TabOrder = 1
      end
    end
    object TabSheet2: TTabSheet
      Caption = 'Guilds found'
      ImageIndex = 1
      object FlowPanelGuilds: TFlowPanel
        Left = 0
        Top = 0
        Width = 281
        Height = 720
        Align = alLeft
        TabOrder = 0
        ExplicitHeight = 712
      end
    end
  end
end
