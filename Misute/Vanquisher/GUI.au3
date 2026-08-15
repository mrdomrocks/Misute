#include-once
#include <ButtonConstants.au3>
#include <ComboConstants.au3>
#include <EditConstants.au3>
#include <FontConstants.au3>
#include <GUIConstantsEx.au3>
#include <GuiEdit.au3>
#include <GuiListView.au3>
#include <GuiRichEdit.au3>
#include <ListViewConstants.au3>
#include <ProgressConstants.au3>
#include <StaticConstants.au3>
#include <TabConstants.au3>
#include <WindowsConstants.au3>

#include "Config.au3"
#include "Log.au3"
#include "BotState.au3"
#include "Maps.au3"
#include "PartyConfig.au3"
#include "BotController.au3"

#cs ----------------------------------------------------------------------------

    GUI.au3 - the display: header with the controls, status cards, a tabbed
    panel for the zone list and party setup, and the activity log.

    Two rules keep it replaceable: event handlers only ever call StartBot(),
    RequestStop() or a Bot_* helper, and everything shown is read from
    BotState.au3, Maps.au3 and PartyConfig.au3 - the GUI is never told what to
    display.

#ce ----------------------------------------------------------------------------

#Region Layout
Global Const $GUI_W = 920
Global Const $GUI_H = 690

Global Const $GUI_MARGIN = 12
Global Const $GUI_HEADER_H = 56
Global Const $GUI_LEFT_W = 330
Global Const $GUI_RIGHT_X = 354
Global Const $GUI_RIGHT_W = 554
#EndRegion Layout

#Region Colours
Global Const $CLR_WINDOW = 0xF2F3F5
Global Const $CLR_TITLE = 0x1A2233
Global Const $CLR_CAPTION = 0x6B7280
Global Const $CLR_VALUE = 0x1A2233
Global Const $CLR_OK = 0x1B7F3B
Global Const $CLR_BUSY = 0x1F5FBF
Global Const $CLR_WARN = 0xB06A00
Global Const $CLR_ERROR = 0xB00020
Global Const $CLR_SIM = 0x7B3FBF
#EndRegion Colours

#Region Controls
Global $g_hMainGui = 0
Global $g_hLogEdit = 0

Global $g_idCharacterCombo = 0
Global $g_idStartButton = 0
Global $g_idStopButton = 0
Global $g_idRefreshButton = 0
Global $g_idRenderingCheckbox = 0
Global $g_idModeBadge = 0

Global $g_idStatusValue = 0
Global $g_idZoneValue = 0
Global $g_idOutpostValue = 0
Global $g_idAttemptValue = 0
Global $g_idActivityValue = 0

Global $g_idRunTimeValue = 0
Global $g_idTotalTimeValue = 0
Global $g_idZoneTimeValue = 0
Global $g_idTimeoutValue = 0

Global $g_idProgressBar = 0
Global $g_idProgressLabel = 0
Global $g_idRemainingValue = 0
Global $g_idVanquishedValue = 0
Global $g_idFailedValue = 0

Global $g_idMapList = 0
Global $g_aidPartyLabels[3]
Global $g_idPartyPathLabel = 0
Global $g_idStatusBar = 0
#EndRegion Controls

#Region GUI state
Global $g_iGuiRevision = -1
Global $g_hGuiRefreshTimer = 0
Global $g_iGuiLogLines = 0
Global $g_bGuiLogRebuilding = False
Global $g_bGuiExitRequested = False
Global $g_sGuiMapSignature = ""

Global Const $eLVCOL_MAP = 0
Global Const $eLVCOL_REGION = 1
Global Const $eLVCOL_PARTY = 2
Global Const $eLVCOL_STATUS = 3
Global Const $eLVCOL_ATTEMPTS = 4
Global Const $eLVCOL_DETAIL = 5
#EndRegion GUI state

#Region Creation
;~ Description: Builds the window and starts showing log output. Call once.
Func GUI_Create()
	$g_hMainGui = GUICreate($VQ_BOT_TITLE & " " & $VQ_BOT_VERSION, $GUI_W, $GUI_H, -1, -1, -1, $WS_EX_WINDOWEDGE)
	GUISetBkColor($CLR_WINDOW, $g_hMainGui)
	GUISetFont(9, $FW_NORMAL, 0, "Segoe UI", $g_hMainGui)

	GUI_CreateHeader()
	GUI_CreateStatusCard()
	GUI_CreateTimerCard()
	GUI_CreateProgressCard()
	GUI_CreateTabs()
	GUI_CreateLog()
	GUI_CreateStatusBar()

	GUISetOnEvent($GUI_EVENT_CLOSE, "GUI_OnClose")
	GUISetState(@SW_SHOW)

	; From now on every log line appears in the console, including the ones
	; written before the window existed.
	VqLog_RegisterSink("GUI_OnLogLine")
	VqLog_ReplayTo("GUI_OnLogLine")

	GUI_BuildMapList()
	$g_hGuiRefreshTimer = TimerInit()
	GUI_Update(True)

	Return $g_hMainGui
EndFunc   ;==>GUI_Create

;~ Description: Title, character selector and the run controls.
Func GUI_CreateHeader()
	Local $idTitle = GUICtrlCreateLabel($VQ_BOT_TITLE, $GUI_MARGIN, 14, 240, 24)
	GUICtrlSetFont($idTitle, 14, $FW_SEMIBOLD, 0, "Segoe UI")
	GUICtrlSetColor($idTitle, $CLR_TITLE)

	$g_idModeBadge = GUICtrlCreateLabel("", $GUI_MARGIN, 36, 250, 18)
	GUICtrlSetFont($g_idModeBadge, 9, $FW_SEMIBOLD, 0, "Segoe UI")

	GUI_CreateCaption("Character", 268, 12, 80)
	If $g_bLoadLoggedChars Then
		$g_idCharacterCombo = GUICtrlCreateCombo($g_sTargetCharacter, 268, 28, 210, 24, _
				BitOR($CBS_DROPDOWN, $CBS_AUTOHSCROLL))
		GUICtrlSetData($g_idCharacterCombo, Bot_GetLoggedCharNames())
	Else
		$g_idCharacterCombo = GUICtrlCreateInput($g_sTargetCharacter, 268, 28, 210, 24)
	EndIf

	$g_idRefreshButton = GUICtrlCreateButton("Refresh", 486, 28, 76, 25)
	GUICtrlSetOnEvent($g_idRefreshButton, "GUI_OnRefreshCharacters")

	$g_idRenderingCheckbox = GUICtrlCreateCheckbox("Render client", 574, 31, 100, 20)
	GUICtrlSetOnEvent($g_idRenderingCheckbox, "GUI_OnToggleRendering")
	GUICtrlSetState($g_idRenderingCheckbox, $GUI_CHECKED)
	GUICtrlSetColor($g_idRenderingCheckbox, $CLR_CAPTION)

	$g_idStartButton = GUICtrlCreateButton("Start", 690, 24, 100, 30)
	GUICtrlSetFont($g_idStartButton, 10, $FW_SEMIBOLD, 0, "Segoe UI")
	GUICtrlSetOnEvent($g_idStartButton, "GUI_OnStart")

	$g_idStopButton = GUICtrlCreateButton("Stop", 798, 24, 100, 30)
	GUICtrlSetFont($g_idStopButton, 10, $FW_SEMIBOLD, 0, "Segoe UI")
	GUICtrlSetOnEvent($g_idStopButton, "GUI_OnStop")
EndFunc   ;==>GUI_CreateHeader

Func GUI_CreateStatusCard()
	Local $iY = $GUI_HEADER_H + 8
	GUI_CreateCard("Current work", $GUI_MARGIN, $iY, $GUI_LEFT_W, 152)

	$g_idStatusValue = GUI_CreateRow("Status", $GUI_MARGIN, $iY + 24)
	$g_idZoneValue = GUI_CreateRow("Zone", $GUI_MARGIN, $iY + 46)
	$g_idOutpostValue = GUI_CreateRow("Outpost", $GUI_MARGIN, $iY + 68)
	$g_idAttemptValue = GUI_CreateRow("Attempt", $GUI_MARGIN, $iY + 90)

	GUI_CreateCaption("Activity", $GUI_MARGIN + 12, $iY + 112, 70)
	$g_idActivityValue = GUICtrlCreateLabel("-", $GUI_MARGIN + 88, $iY + 112, $GUI_LEFT_W - 100, 32)
	GUICtrlSetColor($g_idActivityValue, $CLR_VALUE)
EndFunc   ;==>GUI_CreateStatusCard

Func GUI_CreateTimerCard()
	Local $iY = $GUI_HEADER_H + 168
	GUI_CreateCard("Timers", $GUI_MARGIN, $iY, $GUI_LEFT_W, 122)

	$g_idRunTimeValue = GUI_CreateRow("This run", $GUI_MARGIN, $iY + 24, "00:00:00")
	$g_idTotalTimeValue = GUI_CreateRow("Session", $GUI_MARGIN, $iY + 46, "00:00:00")
	$g_idZoneTimeValue = GUI_CreateRow("This zone", $GUI_MARGIN, $iY + 68, "00:00:00")
	$g_idTimeoutValue = GUI_CreateRow("Timeout in", $GUI_MARGIN, $iY + 90, "--:--:--")
EndFunc   ;==>GUI_CreateTimerCard

Func GUI_CreateProgressCard()
	Local $iY = $GUI_HEADER_H + 298
	GUI_CreateCard("Progress", $GUI_MARGIN, $iY, $GUI_LEFT_W, 110)

	$g_idProgressBar = GUICtrlCreateProgress($GUI_MARGIN + 12, $iY + 28, $GUI_LEFT_W - 24, 16, $PBS_SMOOTH)
	$g_idProgressLabel = GUICtrlCreateLabel("0 / 0 zones", $GUI_MARGIN + 12, $iY + 50, $GUI_LEFT_W - 24, 18)
	GUICtrlSetColor($g_idProgressLabel, $CLR_CAPTION)

	$g_idRemainingValue = GUICtrlCreateLabel("Remaining 0", $GUI_MARGIN + 12, $iY + 76, 100, 18)
	$g_idVanquishedValue = GUICtrlCreateLabel("Vanquished 0", $GUI_MARGIN + 112, $iY + 76, 110, 18)
	GUICtrlSetColor($g_idVanquishedValue, $CLR_OK)
	$g_idFailedValue = GUICtrlCreateLabel("Failed 0", $GUI_MARGIN + 226, $iY + 76, 90, 18)
	GUICtrlSetColor($g_idFailedValue, $CLR_ERROR)
EndFunc   ;==>GUI_CreateProgressCard

;~ Description: Zone list and party setup, side by side in a tab control so the
;~              window stays one screenful.
Func GUI_CreateTabs()
	Local $iY = $GUI_HEADER_H + 8
	Local $iHeight = 400

	GUICtrlCreateTab($GUI_RIGHT_X, $iY, $GUI_RIGHT_W, $iHeight)

	GUICtrlCreateTabItem("Zones")
	$g_idMapList = GUICtrlCreateListView("Zone|Region|Party|Status|Att|Detail", _
			$GUI_RIGHT_X + 8, $iY + 30, $GUI_RIGHT_W - 16, $iHeight - 42, -1, _
			BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
	_GUICtrlListView_SetColumnWidth($g_idMapList, $eLVCOL_MAP, 152)
	_GUICtrlListView_SetColumnWidth($g_idMapList, $eLVCOL_REGION, 92)
	_GUICtrlListView_SetColumnWidth($g_idMapList, $eLVCOL_PARTY, 40)
	_GUICtrlListView_SetColumnWidth($g_idMapList, $eLVCOL_STATUS, 76)
	_GUICtrlListView_SetColumnWidth($g_idMapList, $eLVCOL_ATTEMPTS, 30)
	_GUICtrlListView_SetColumnWidth($g_idMapList, $eLVCOL_DETAIL, 126)

	GUICtrlCreateTabItem("Party")
	GUICtrlCreateLabel("The team taken into a zone depends on the party size the area allows." & @CRLF & _
			"Edit the sections below in Vanquisher.ini, then press Reload.", _
			$GUI_RIGHT_X + 16, $iY + 36, $GUI_RIGHT_W - 32, 36)
	GUICtrlSetColor(-1, $CLR_CAPTION)

	For $i = 0 To UBound($PARTY_SIZES) - 1
		Local $iRowY = $iY + 84 + ($i * 62)
		GUI_CreateCaption($PARTY_SIZES[$i] & " man areas", $GUI_RIGHT_X + 16, $iRowY, 120)
		$g_aidPartyLabels[$i] = GUICtrlCreateLabel("-", $GUI_RIGHT_X + 16, $iRowY + 20, $GUI_RIGHT_W - 32, 32)
		GUICtrlSetColor($g_aidPartyLabels[$i], $CLR_VALUE)
	Next

	$g_idPartyPathLabel = GUICtrlCreateLabel($PARTY_INI_FILE, $GUI_RIGHT_X + 16, $iY + 284, $GUI_RIGHT_W - 32, 32)
	GUICtrlSetColor($g_idPartyPathLabel, $CLR_CAPTION)

	Local $idReload = GUICtrlCreateButton("Reload", $GUI_RIGHT_X + 16, $iY + 328, 90, 26)
	GUICtrlSetOnEvent($idReload, "GUI_OnReloadParty")
	Local $idEdit = GUICtrlCreateButton("Open ini", $GUI_RIGHT_X + 114, $iY + 328, 90, 26)
	GUICtrlSetOnEvent($idEdit, "GUI_OnEditParty")

	GUICtrlCreateTabItem("")
EndFunc   ;==>GUI_CreateTabs

Func GUI_CreateLog()
	Local $iY = $GUI_HEADER_H + 416
	GUI_CreateCard("Activity log", $GUI_MARGIN, $iY, $GUI_W - ($GUI_MARGIN * 2), 168)

	$g_hLogEdit = _GUICtrlRichEdit_Create($g_hMainGui, "", $GUI_MARGIN + 10, $iY + 24, _
			$GUI_W - ($GUI_MARGIN * 2) - 20, 134, _
			BitOR($ES_AUTOVSCROLL, $ES_MULTILINE, $WS_VSCROLL, $ES_READONLY), $WS_EX_STATICEDGE)
	_GUICtrlRichEdit_SetBkColor($g_hLogEdit, 0xFFFFFF)
	_GUICtrlRichEdit_SetFont($g_hLogEdit, 9, "Consolas")
EndFunc   ;==>GUI_CreateLog

Func GUI_CreateStatusBar()
	$g_idStatusBar = GUICtrlCreateLabel("", $GUI_MARGIN, $GUI_H - 26, $GUI_W - ($GUI_MARGIN * 2), 18)
	GUICtrlSetColor($g_idStatusBar, $CLR_CAPTION)
EndFunc   ;==>GUI_CreateStatusBar

Func GUI_Shutdown()
	VqLog_ClearSink()

	; The rich edit control has to be released before its parent window.
	If $g_hLogEdit <> 0 Then _GUICtrlRichEdit_Destroy($g_hLogEdit)
	If $g_hMainGui <> 0 Then GUIDelete($g_hMainGui)
	$g_hMainGui = 0
	$g_hLogEdit = 0
EndFunc   ;==>GUI_Shutdown
#EndRegion Creation

#Region Building blocks
;~ Description: A titled panel. Groups are used rather than drawn boxes so the
;~              window follows whatever Windows theme the user has.
Func GUI_CreateCard($sTitle, $iX, $iY, $iWidth, $iHeight)
	Local $idGroup = GUICtrlCreateGroup(" " & $sTitle & " ", $iX, $iY, $iWidth, $iHeight)
	GUICtrlSetFont($idGroup, 9, $FW_SEMIBOLD, 0, "Segoe UI")
	GUICtrlSetColor($idGroup, $CLR_TITLE)
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	Return $idGroup
EndFunc   ;==>GUI_CreateCard

Func GUI_CreateCaption($sText, $iX, $iY, $iWidth)
	Local $idLabel = GUICtrlCreateLabel($sText, $iX, $iY, $iWidth, 18)
	GUICtrlSetColor($idLabel, $CLR_CAPTION)
	Return $idLabel
EndFunc   ;==>GUI_CreateCaption

;~ Description: A caption/value pair inside a card. Returns the value label.
Func GUI_CreateRow($sCaption, $iCardX, $iY, $sValue = "-")
	GUI_CreateCaption($sCaption, $iCardX + 12, $iY, 74)

	Local $idValue = GUICtrlCreateLabel($sValue, $iCardX + 88, $iY, $GUI_LEFT_W - 100, 18)
	GUICtrlSetColor($idValue, $CLR_VALUE)
	Return $idValue
EndFunc   ;==>GUI_CreateRow
#EndRegion Building blocks

#Region Event handlers
;~ Handlers only ever ask the controller for something. No bot logic lives here.

Func GUI_OnStart()
	If State_IsBusy() Then Return

	StartBot(GUICtrlRead($g_idCharacterCombo))
	GUI_Update(True)
EndFunc   ;==>GUI_OnStart

Func GUI_OnStop()
	RequestStop()
	GUI_Update(True)
EndFunc   ;==>GUI_OnStop

Func GUI_OnRefreshCharacters()
	If State_IsBusy() Then Return

	GUICtrlSetData($g_idCharacterCombo, "")
	GUICtrlSetData($g_idCharacterCombo, Bot_GetLoggedCharNames())
	VqLog_Info("Character list refreshed.")
EndFunc   ;==>GUI_OnRefreshCharacters

Func GUI_OnToggleRendering()
	Bot_SetRendering(GUICtrlRead($g_idRenderingCheckbox) = $GUI_CHECKED)
EndFunc   ;==>GUI_OnToggleRendering

Func GUI_OnReloadParty()
	PartyConfig_Load()
	GUI_UpdateParty()
EndFunc   ;==>GUI_OnReloadParty

Func GUI_OnEditParty()
	ShellExecute($PARTY_INI_FILE)
EndFunc   ;==>GUI_OnEditParty

;~ Description: Closing the window asks the bot to stop first; the application
;~              loop exits once the workflow has come to a safe halt.
Func GUI_OnClose()
	$g_bGuiExitRequested = True

	If Bot_IsActive() Then
		VqLog_Status("Close requested - stopping the bot before exiting.")
		RequestStop()
	EndIf
EndFunc   ;==>GUI_OnClose

Func GUI_IsExitRequested()
	Return $g_bGuiExitRequested
EndFunc   ;==>GUI_IsExitRequested
#EndRegion Event handlers

#Region Refresh
;~ Description: Repaints the window. Called from the application loop; only does
;~              work when the bot state changed or the refresh interval elapsed,
;~              so the labels do not flicker and the CPU stays idle.
Func GUI_Update($bForce = False)
	If $g_hMainGui = 0 Then Return

	Local $iRevision = State_GetRevision()

	If Not $bForce Then
		Local $iSinceRepaint = TimerDiff($g_hGuiRefreshTimer)
		If $iSinceRepaint < $GUI_MIN_REPAINT_MS Then Return
		If $iRevision = $g_iGuiRevision And $iSinceRepaint < $GUI_REFRESH_MS Then Return
	EndIf

	$g_iGuiRevision = $iRevision
	$g_hGuiRefreshTimer = TimerInit()

	GUI_UpdateStatusPanel()
	GUI_UpdateTimers()
	GUI_UpdateProgress()
	GUI_UpdateMapList()
	GUI_UpdateButtons()
	GUI_UpdateTitle()
EndFunc   ;==>GUI_Update

;~ Description: Lets a long, blocking adapter call keep the window alive; see
;~              State_Yield(). Registered by App.au3.
Func GUI_Pump()
	GUI_Update(True)
EndFunc   ;==>GUI_Pump

Func GUI_UpdateStatusPanel()
	GUI_SetText($g_idStatusValue, State_GetStatusText())
	GUICtrlSetColor($g_idStatusValue, GUI_StateColour())

	GUI_SetText($g_idZoneValue, GUI_OrDash(State_GetCurrentMapName()))
	GUI_SetText($g_idOutpostValue, GUI_OrDash(State_GetCurrentOutpostName()))

	Local $sAttempt = "-"
	If State_GetAttempt() > 0 Then $sAttempt = State_GetAttempt() & " of " & State_GetAttemptMax()
	GUI_SetText($g_idAttemptValue, $sAttempt)

	GUI_SetText($g_idActivityValue, GUI_OrDash(State_GetActivity()))
	GUI_SetText($g_idStatusBar, State_GetBotStateName() & "  -  " & Maps_Count() & " zones in the database")
EndFunc   ;==>GUI_UpdateStatusPanel

Func GUI_UpdateTimers()
	GUI_SetText($g_idRunTimeValue, State_FormatDuration(State_GetRunElapsedMs()))
	GUI_SetText($g_idTotalTimeValue, State_FormatDuration(State_GetTotalElapsedMs()))

	If State_IsZoneTimerRunning() Then
		GUI_SetText($g_idZoneTimeValue, State_FormatDuration(State_GetZoneElapsedMs()))
		GUI_SetText($g_idTimeoutValue, State_FormatDuration(State_GetZoneRemainingMs()))
	Else
		GUI_SetText($g_idZoneTimeValue, "00:00:00")
		GUI_SetText($g_idTimeoutValue, "--:--:--")
	EndIf
EndFunc   ;==>GUI_UpdateTimers

Func GUI_UpdateProgress()
	Local $iTotal = State_GetMapsTotal()
	Local $iDone = State_GetMapsVanquished() + State_GetMapsFailed()

	If GUICtrlRead($g_idProgressBar) <> State_GetProgressPercent() Then
		GUICtrlSetData($g_idProgressBar, State_GetProgressPercent())
	EndIf

	GUI_SetText($g_idProgressLabel, $iDone & " / " & $iTotal & " zones dealt with")
	GUI_SetText($g_idRemainingValue, "Remaining " & State_GetMapsRemaining())
	GUI_SetText($g_idVanquishedValue, "Vanquished " & State_GetMapsVanquished())
	GUI_SetText($g_idFailedValue, "Failed " & State_GetMapsFailed())
EndFunc   ;==>GUI_UpdateProgress

Func GUI_UpdateParty()
	For $i = 0 To UBound($PARTY_SIZES) - 1
		Local $iSize = $PARTY_SIZES[$i]
		Local $sText = StringReplace(PartyConfig_Describe($iSize), $iSize & " man: ", "")
		GUI_SetText($g_aidPartyLabels[$i], $sText)
	Next
EndFunc   ;==>GUI_UpdateParty

Func GUI_UpdateButtons()
	Local $bBusy = State_IsBusy()

	GUI_SetControlEnabled($g_idStartButton, Not $bBusy)
	GUI_SetControlEnabled($g_idStopButton, $bBusy And Not State_IsStopRequested())
	GUI_SetControlEnabled($g_idRefreshButton, Not $bBusy)
	GUI_SetControlEnabled($g_idCharacterCombo, Not $bBusy)
EndFunc   ;==>GUI_UpdateButtons

Func GUI_UpdateTitle()
	Local $sTitle = $VQ_BOT_TITLE & " " & $VQ_BOT_VERSION
	If State_GetCharacterName() <> "" Then $sTitle &= " - " & State_GetCharacterName()

	If WinGetTitle($g_hMainGui) <> $sTitle Then WinSetTitle($g_hMainGui, "", $sTitle)

	Local $sBadge = ($g_bSimulationMode) ? "SIMULATION - no client attached" : "Live client"
	If State_IsConnected() And Not $g_bSimulationMode Then $sBadge = "Connected to " & State_GetCharacterName()
	GUI_SetText($g_idModeBadge, $sBadge)
	GUICtrlSetColor($g_idModeBadge, ($g_bSimulationMode) ? $CLR_SIM : $CLR_OK)
EndFunc   ;==>GUI_UpdateTitle

;~ Description: The colour the status line is written in, so the window can be
;~              read at a glance from across the room.
Func GUI_StateColour()
	Switch State_GetBotState()
		Case $eBOT_IDLE
			Return $CLR_CAPTION
		Case $eBOT_FINISHED
			Return $CLR_OK
		Case $eBOT_ERROR
			Return $CLR_ERROR
		Case $eBOT_RECOVERING, $eBOT_STOPPING
			Return $CLR_WARN
		Case Else
			Return $CLR_BUSY
	EndSwitch
EndFunc   ;==>GUI_StateColour
#EndRegion Refresh

#Region Zone list
;~ Description: One row per zone, created once. Only the cells that change are
;~              rewritten afterwards, which avoids the flicker of rebuilding.
Func GUI_BuildMapList()
	_GUICtrlListView_DeleteAllItems($g_idMapList)

	For $i = 0 To Maps_Count() - 1
		_GUICtrlListView_AddItem($g_idMapList, Maps_GetName($i))
		_GUICtrlListView_AddSubItem($g_idMapList, $i, Maps_GetRegion($i), $eLVCOL_REGION)
		_GUICtrlListView_AddSubItem($g_idMapList, $i, "-", $eLVCOL_PARTY)
		_GUICtrlListView_AddSubItem($g_idMapList, $i, Maps_StatusText(Maps_GetStatus($i)), $eLVCOL_STATUS)
		_GUICtrlListView_AddSubItem($g_idMapList, $i, "0", $eLVCOL_ATTEMPTS)
		_GUICtrlListView_AddSubItem($g_idMapList, $i, "", $eLVCOL_DETAIL)
	Next

	GUI_UpdateParty()
EndFunc   ;==>GUI_BuildMapList

Func GUI_UpdateMapList()
	; Reading the list view is far more expensive than reading the map array, so
	; the rows are only touched when something in the array actually moved.
	Local $sSignature = ""
	For $i = 0 To Maps_Count() - 1
		$sSignature &= Maps_GetStatus($i) & "," & Maps_GetAttempts($i) & "," & _
				Maps_GetPartySize($i) & "," & Maps_GetLastResult($i) & "|"
	Next

	If $sSignature = $g_sGuiMapSignature Then Return
	$g_sGuiMapSignature = $sSignature

	For $i = 0 To Maps_Count() - 1
		GUI_SetListViewCell($i, $eLVCOL_STATUS, Maps_StatusText(Maps_GetStatus($i)))
		GUI_SetListViewCell($i, $eLVCOL_ATTEMPTS, String(Maps_GetAttempts($i)))

		Local $iPartySize = Maps_GetPartySize($i)
		GUI_SetListViewCell($i, $eLVCOL_PARTY, ($iPartySize > 0) ? String($iPartySize) : "-")

		Local $sDetail = Maps_GetLastResult($i)
		If $sDetail = "" Then $sDetail = Maps_GetOutpostName($i)
		GUI_SetListViewCell($i, $eLVCOL_DETAIL, $sDetail)
	Next
EndFunc   ;==>GUI_UpdateMapList

Func GUI_SetListViewCell($iRow, $iColumn, $sText)
	If _GUICtrlListView_GetItemText($g_idMapList, $iRow, $iColumn) = $sText Then Return
	_GUICtrlListView_SetItemText($g_idMapList, $iRow, $sText, $iColumn)
EndFunc   ;==>GUI_SetListViewCell
#EndRegion Zone list

#Region Log console
;~ Description: Log sink. Registered with VqLog_RegisterSink() so the bot can log
;~              without knowing a window exists.
Func GUI_OnLogLine($sLine, $iLevel)
	If $g_hLogEdit = 0 Then Return

	_GUICtrlRichEdit_SetSel($g_hLogEdit, -1, -1)
	_GUICtrlRichEdit_SetCharColor($g_hLogEdit, VqLog_LevelColour($iLevel))
	_GUICtrlRichEdit_AppendText($g_hLogEdit, (($g_iGuiLogLines > 0) ? @CRLF : "") & $sLine)
	_GUICtrlEdit_Scroll($g_hLogEdit, 1)

	$g_iGuiLogLines += 1
	If $g_iGuiLogLines > $GUI_LOG_MAX_LINES And Not $g_bGuiLogRebuilding Then GUI_RebuildLog()
EndFunc   ;==>GUI_OnLogLine

;~ Description: Redraws the console from the log ring buffer. Keeps memory flat
;~              during unattended runs that produce thousands of lines.
Func GUI_RebuildLog()
	$g_bGuiLogRebuilding = True

	_GUICtrlRichEdit_SetText($g_hLogEdit, "")
	$g_iGuiLogLines = 0
	VqLog_ReplayTo("GUI_OnLogLine")

	$g_bGuiLogRebuilding = False
EndFunc   ;==>GUI_RebuildLog
#EndRegion Log console

#Region Small helpers
;~ Description: Writes a label only when the text actually changed.
Func GUI_SetText($idControl, $sText)
	If $idControl = 0 Then Return
	If GUICtrlRead($idControl) = $sText Then Return
	GUICtrlSetData($idControl, $sText)
EndFunc   ;==>GUI_SetText

Func GUI_SetControlEnabled($idControl, $bEnabled)
	If $idControl = 0 Then Return
	GUICtrlSetState($idControl, ($bEnabled) ? $GUI_ENABLE : $GUI_DISABLE)
EndFunc   ;==>GUI_SetControlEnabled

Func GUI_OrDash($sText)
	Return ($sText = "") ? "-" : $sText
EndFunc   ;==>GUI_OrDash
#EndRegion Small helpers
