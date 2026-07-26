#include-once
#include <ButtonConstants.au3>
#include <ComboConstants.au3>
#include <EditConstants.au3>
#include <GUIConstantsEx.au3>
#include <StaticConstants.au3>
#include <WindowsConstants.au3>
#include <Date.au3>
#include <TabConstants.au3>
#include <ProgressConstants.au3>
#include <GuiTab.au3>

; Main Form
$MainGui = GUICreate($BotTitle, 316, 362, 244, 170, -1, BitOR($WS_EX_TOPMOST,$WS_EX_WINDOWEDGE))

; Combo Boxes For Character Selection & Farms
$Group3 = GUICtrlCreateGroup("Misute", 8, 7, 300, 347, -1,  $WS_EX_TRANSPARENT)
$Group1 = GUICtrlCreateGroup("Select Your Character", 16, 24, 160, 49)

Global $GUINameCombo
If $doLoadLoggedChars Then
    $GUINameCombo = GUICtrlCreateCombo($g_s_MainCharName, 24, 40, 144, 25, BitOR($CBS_DROPDOWN,$CBS_AUTOHSCROLL))
    GUICtrlSetData(-1, Scanner_GetLoggedCharNames())
Else
    $GUINameCombo = GUICtrlCreateInput($g_s_MainCharName, 24, 40, 144, 25)
EndIf
GUICtrlCreateGroup("", -99, -99, 1, 1)

; Buttons/Checkboxes
$GUIStartButton = GUICtrlCreateButton("Start", 185, 38, 57, 25)
GUICtrlSetOnEvent($GUIStartButton, "GuiButtonHandler")
$GUIRefreshButton = GUICtrlCreateButton("Refresh", 246, 38, 57, 25)
GUICtrlSetOnEvent($GUIRefreshButton, "GuiButtonHandler")
$GUIToggleRendering = GUICtrlCreateCheckbox("Rendering?", 30, 329, 105, 17)
GUICtrlSetOnEvent($GUIToggleRendering, "GuiButtonHandler")
GUICtrlSetState($GUIToggleRendering, $GUI_DISABLE)

; RichEdit Output Box
$g_h_EditText = _GUICtrlRichEdit_Create($MainGui, "", 16, 133, 284, 114, BitOR($ES_AUTOVSCROLL, $ES_MULTILINE, $WS_VSCROLL, $ES_READONLY), $WS_EX_STATICEDGE)
_GUICtrlRichEdit_SetBkColor($g_h_EditText, $COLOR_WHITE)

; Images/Labels
$Pic1 = GUICtrlCreatePic("Misute.jpg", 30, 256, 256, 71)
$Label3 = GUICtrlCreateLabel("Run Time:", 198, 86, 53, 17)
$Label4 = GUICtrlCreateLabel("Total Time:", 194, 103, 57, 17)
$RunTimeLbl = GUICtrlCreateLabel("00:00:00", 249, 86, 46, 17)
$TotalTimeLbl = GUICtrlCreateLabel("00:00:00", 249, 103, 46, 17)
GUICtrlCreateGroup("", -99, -99, 1, 1)

GUISetOnEvent($GUI_EVENT_CLOSE, "GuiButtonHandler")
GUISetState(@SW_SHOW)

Func GuiButtonHandler()
    Switch @GUI_CtrlId
        Case $GUIStartButton
            If Not $BotRunning Then
                If Not $Bot_Core_Initialized Then
                    InitializeBot()
                    WinSetTitle($MainGui, "", player_GetCharname())
                    GUICtrlSetState($GUINameCombo, $GUI_DISABLE)
                    GUICtrlSetState($GUIRefreshButton, $GUI_DISABLE)
                    $Bot_Core_Initialized = True
                EndIf

                GUICtrlSetState($GUIToggleRendering, $GUI_ENABLE)
                GUICtrlSetState($GUIStartButton, $GUI_DISABLE)
                GUICtrlSetData($GUIStartButton, "Stop")
                GUICtrlSetState($GUIStartButton, $GUI_ENABLE)
                $BotRunning = True

            ElseIf $BotRunning Then
                GUICtrlSetState($FarmCombo, $GUI_ENABLE)
                
                GUICTrlSetState($GUIStartButton, $GUI_DISABLE)
                GUICtrlSetData($GUIStartButton, "Pausing...")
                LogStatus("Bot will pause, please wait..")
                $BotRunning = False
            EndIf

        Case $GUIRefreshButton
            GUICtrlSetData($GUINameCombo, "")
            GUICtrlSetData($GUINameCombo, Scanner_GetLoggedCharNames())

        Case $GUIToggleRendering
            Ui_ToggleRendering()

        Case $GUI_EVENT_CLOSE
            Exit
    EndSwitch
EndFunc

Func InitializeBot()
    GUICtrlSetState($GUIStartButton, $GUI_DISABLE)
    Local $g_s_MainCharName = GUICtrlRead($GUINameCombo)
    If $g_s_MainCharName=="" Then
        If Core_Initialize(ProcessExists("gw.exe"), True) = 0 Then
            MsgBox(0, "Error", "Guild Wars is not running.")
            Exit
        EndIf
    ElseIf $ProcessID Then
        $proc_id_int = Number($ProcessID, 2)
        If Core_Initialize($proc_id_int, True) = 0 Then
            MsgBox(0, "Error", "Could not Find a ProcessID or somewhat '"&$proc_id_int&"'  "&VarGetType($proc_id_int)&"'")
            Exit
            If ProcessExists($proc_id_int) Then
                ProcessClose($proc_id_int)
            EndIf
            Exit
        EndIf
    Else
        If Core_Initialize($g_s_MainCharName, True) = 0 Then
            MsgBox(0, "Error", "Could not Find a Guild Wars client with a Character named '"&$g_s_MainCharName&"'")
            Exit
        EndIf
    EndIf

    $Bot_Core_Initialized = True
EndFunc

Func UpdateStats()
    GUICtrlSetData($RunTimeLbl, FormatElapsedTime($RunTime))
EndFunc

Func UpdateTotalTime()
    GUICtrlSetData($TotalTimeLbl, FormatElapsedTime($TotalTime))
EndFunc

Func ResetStart()
    GUICtrlSetState($GUIStartButton, $GUI_ENABLE)
    GUICtrlSetData($GUIStartButton, "Start")
    LogStatus("Bot paused.")
    Sleep(500)
EndFunc
