#include-once
#include "Config.au3"

#cs ----------------------------------------------------------------------------

    BotState.au3 - the contract between the GUI and the bot. The controller
    writes what it is doing, the GUI reads it; neither knows the other exists.
    Deliberately dumb: values, durations and timers, no workflow decisions.

#ce ----------------------------------------------------------------------------

#Region Bot states
Global Const $eBOT_IDLE = 0            ; not running, waiting for Start
Global Const $eBOT_INITIALISING = 1    ; connecting to the client
Global Const $eBOT_CHECKING = 2        ; reading vanquished status of each zone
Global Const $eBOT_NEXT_MAP = 3        ; picking the next zone off the queue
Global Const $eBOT_TRAVELLING = 4      ; travelling to the starting outpost
Global Const $eBOT_PREPARING = 5       ; hard mode and the hero/henchman party
Global Const $eBOT_ENTERING = 6        ; walking to the zone through portals
Global Const $eBOT_VANQUISHING = 7     ; running the zone route / killing foes
Global Const $eBOT_CONFIRMING = 8      ; verifying the zone really is vanquished
Global Const $eBOT_RECOVERING = 9      ; getting back to a known safe state
Global Const $eBOT_STOPPING = 10       ; honouring a stop request
Global Const $eBOT_FINISHED = 11       ; queue emptied, nothing left to do
Global Const $eBOT_ERROR = 12          ; unrecoverable, needs the user
#EndRegion Bot states

#Region State storage
Global $g_iBotState = $eBOT_IDLE
Global $g_sStatusText = "Idle"

Global $g_sCurrentMapName = ""
Global $g_sCurrentOutpostName = ""
Global $g_iCurrentAttempt = 0
Global $g_iCurrentAttemptMax = $MAX_RETRIES
Global $g_sCurrentActivity = ""         ; free text detail, eg pathfinder progress

Global $g_iMapsTotal = 0
Global $g_iMapsRemaining = 0
Global $g_iMapsVanquished = 0
Global $g_iMapsFailed = 0

Global $g_sCharacterName = ""
Global $g_bConnected = False

Global $g_hZoneTimer = 0                ; per zone-attempt timer (the 2h ceiling)
Global $g_hRunTimer = 0                 ; current run
Global $g_hTotalTimer = 0               ; whole application lifetime
Global $g_iLastRunMs = 0                ; elapsed time of the last finished run

Global $g_bStopRequested = False

;~ Bumped on every change so a display can redraw only when something moved.
Global $g_iStateRevision = 0

;~ Optional host callback used by State_Yield(); see the note on that function.
Global $g_sPumpHandler = ""
Global $g_hPumpTimer = 0
#EndRegion State storage

#Region Lifecycle
Func State_Init()
	$g_iBotState = $eBOT_IDLE
	$g_sStatusText = "Idle"
	$g_hTotalTimer = TimerInit()
	$g_hPumpTimer = TimerInit()
	State_Touch()
EndFunc   ;==>State_Init

;~ Description: Clears everything belonging to a single run. Called by the
;~              controller when Start is pressed.
Func State_ResetForRun()
	$g_sCurrentMapName = ""
	$g_sCurrentOutpostName = ""
	$g_sCurrentActivity = ""
	$g_iCurrentAttempt = 0
	$g_iMapsTotal = 0
	$g_iMapsRemaining = 0
	$g_iMapsVanquished = 0
	$g_iMapsFailed = 0
	$g_bStopRequested = False
	$g_hZoneTimer = 0
	$g_hRunTimer = TimerInit()
	State_Touch()
EndFunc   ;==>State_ResetForRun
#EndRegion Lifecycle

#Region Bot state
Func State_SetBotState($iState)
	If $g_iBotState = $iState Then Return
	$g_iBotState = $iState
	State_Touch()
EndFunc   ;==>State_SetBotState

Func State_GetBotState()
	Return $g_iBotState
EndFunc   ;==>State_GetBotState

;~ Description: True while the bot is doing something, ie Start should be
;~              disabled and Stop enabled.
Func State_IsBusy()
	Switch $g_iBotState
		Case $eBOT_IDLE, $eBOT_FINISHED, $eBOT_ERROR
			Return False
		Case Else
			Return True
	EndSwitch
EndFunc   ;==>State_IsBusy

Func State_GetBotStateName($iState = -1)
	If $iState = -1 Then $iState = $g_iBotState

	Switch $iState
		Case $eBOT_IDLE
			Return "Idle"
		Case $eBOT_INITIALISING
			Return "Initialising"
		Case $eBOT_CHECKING
			Return "Checking zones"
		Case $eBOT_NEXT_MAP
			Return "Selecting zone"
		Case $eBOT_TRAVELLING
			Return "Travelling"
		Case $eBOT_PREPARING
			Return "Forming party"
		Case $eBOT_ENTERING
			Return "Walking in"
		Case $eBOT_VANQUISHING
			Return "Vanquishing"
		Case $eBOT_CONFIRMING
			Return "Confirming"
		Case $eBOT_RECOVERING
			Return "Recovering"
		Case $eBOT_STOPPING
			Return "Stopping"
		Case $eBOT_FINISHED
			Return "Finished"
		Case $eBOT_ERROR
			Return "Error"
		Case Else
			Return "Unknown"
	EndSwitch
EndFunc   ;==>State_GetBotStateName
#EndRegion Bot state

#Region Status text
Func State_SetStatusText($sText)
	If $g_sStatusText = $sText Then Return
	$g_sStatusText = $sText
	State_Touch()
EndFunc   ;==>State_SetStatusText

Func State_GetStatusText()
	Return $g_sStatusText
EndFunc   ;==>State_GetStatusText

Func State_SetActivity($sText)
	If $g_sCurrentActivity = $sText Then Return
	$g_sCurrentActivity = $sText
	State_Touch()
EndFunc   ;==>State_SetActivity

Func State_GetActivity()
	Return $g_sCurrentActivity
EndFunc   ;==>State_GetActivity
#EndRegion Status text

#Region Current map
Func State_SetCurrentMap($sMapName, $sOutpostName)
	$g_sCurrentMapName = $sMapName
	$g_sCurrentOutpostName = $sOutpostName
	State_Touch()
EndFunc   ;==>State_SetCurrentMap

Func State_ClearCurrentMap()
	State_SetCurrentMap("", "")
	$g_iCurrentAttempt = 0
	State_Touch()
EndFunc   ;==>State_ClearCurrentMap

Func State_GetCurrentMapName()
	Return $g_sCurrentMapName
EndFunc   ;==>State_GetCurrentMapName

Func State_GetCurrentOutpostName()
	Return $g_sCurrentOutpostName
EndFunc   ;==>State_GetCurrentOutpostName

Func State_SetAttempt($iAttempt, $iMax = $MAX_RETRIES)
	$g_iCurrentAttempt = $iAttempt
	$g_iCurrentAttemptMax = $iMax
	State_Touch()
EndFunc   ;==>State_SetAttempt

Func State_GetAttempt()
	Return $g_iCurrentAttempt
EndFunc   ;==>State_GetAttempt

Func State_GetAttemptMax()
	Return $g_iCurrentAttemptMax
EndFunc   ;==>State_GetAttemptMax
#EndRegion Current map

#Region Counters
Func State_SetCounters($iTotal, $iRemaining, $iVanquished, $iFailed)
	If $g_iMapsTotal = $iTotal And $g_iMapsRemaining = $iRemaining And _
			$g_iMapsVanquished = $iVanquished And $g_iMapsFailed = $iFailed Then Return

	$g_iMapsTotal = $iTotal
	$g_iMapsRemaining = $iRemaining
	$g_iMapsVanquished = $iVanquished
	$g_iMapsFailed = $iFailed
	State_Touch()
EndFunc   ;==>State_SetCounters

Func State_GetMapsTotal()
	Return $g_iMapsTotal
EndFunc   ;==>State_GetMapsTotal

Func State_GetMapsRemaining()
	Return $g_iMapsRemaining
EndFunc   ;==>State_GetMapsRemaining

Func State_GetMapsVanquished()
	Return $g_iMapsVanquished
EndFunc   ;==>State_GetMapsVanquished

Func State_GetMapsFailed()
	Return $g_iMapsFailed
EndFunc   ;==>State_GetMapsFailed

;~ Description: Percentage of the run that is dealt with (done or given up on).
Func State_GetProgressPercent()
	If $g_iMapsTotal <= 0 Then Return 0
	Return Int((($g_iMapsVanquished + $g_iMapsFailed) / $g_iMapsTotal) * 100)
EndFunc   ;==>State_GetProgressPercent
#EndRegion Counters

#Region Connection
Func State_SetConnected($bConnected, $sCharacterName = "")
	$g_bConnected = $bConnected
	If $sCharacterName <> "" Then $g_sCharacterName = $sCharacterName
	State_Touch()
EndFunc   ;==>State_SetConnected

Func State_IsConnected()
	Return $g_bConnected
EndFunc   ;==>State_IsConnected

Func State_GetCharacterName()
	Return $g_sCharacterName
EndFunc   ;==>State_GetCharacterName
#EndRegion Connection

#Region Timers
;~ Description: Starts the ceiling timer for one zone attempt. Called every time
;~              an attempt begins, never re-used between attempts.
Func State_StartZoneTimer()
	$g_hZoneTimer = TimerInit()
	State_Touch()
EndFunc   ;==>State_StartZoneTimer

Func State_ClearZoneTimer()
	$g_hZoneTimer = 0
	State_Touch()
EndFunc   ;==>State_ClearZoneTimer

Func State_IsZoneTimerRunning()
	Return ($g_hZoneTimer <> 0)
EndFunc   ;==>State_IsZoneTimerRunning

Func State_GetZoneElapsedMs()
	If $g_hZoneTimer = 0 Then Return 0
	Return TimerDiff($g_hZoneTimer)
EndFunc   ;==>State_GetZoneElapsedMs

Func State_GetZoneRemainingMs()
	If $g_hZoneTimer = 0 Then Return $g_iZoneTimeoutMs
	Local $iRemaining = $g_iZoneTimeoutMs - TimerDiff($g_hZoneTimer)
	Return ($iRemaining > 0) ? $iRemaining : 0
EndFunc   ;==>State_GetZoneRemainingMs

;~ Description: True when the current attempt has used its whole allowance.
Func State_HasZoneTimedOut()
	If $g_hZoneTimer = 0 Then Return False
	Return (TimerDiff($g_hZoneTimer) >= $g_iZoneTimeoutMs)
EndFunc   ;==>State_HasZoneTimedOut

Func State_GetRunElapsedMs()
	If $g_hRunTimer = 0 Then Return $g_iLastRunMs
	Return TimerDiff($g_hRunTimer)
EndFunc   ;==>State_GetRunElapsedMs

Func State_StopRunTimer()
	If $g_hRunTimer <> 0 Then $g_iLastRunMs = TimerDiff($g_hRunTimer)
	$g_hRunTimer = 0
	State_Touch()
EndFunc   ;==>State_StopRunTimer

Func State_GetTotalElapsedMs()
	If $g_hTotalTimer = 0 Then Return 0
	Return TimerDiff($g_hTotalTimer)
EndFunc   ;==>State_GetTotalElapsedMs

;~ Description: Milliseconds as HH:MM:SS for display.
Func State_FormatDuration($iMilliseconds)
	If Not IsNumber($iMilliseconds) Or $iMilliseconds < 0 Then Return "00:00:00"

	Local $iSeconds = Int($iMilliseconds / 1000)
	Local $iHours = Int($iSeconds / 3600)
	Local $iMinutes = Int(Mod($iSeconds, 3600) / 60)
	Return StringFormat("%02d:%02d:%02d", $iHours, $iMinutes, Mod($iSeconds, 60))
EndFunc   ;==>State_FormatDuration
#EndRegion Timers

#Region Stop request
;~ Description: Asks the workflow to stop at the next safe point. Called from a
;~              GUI event handler, which must never block.
Func State_RequestStop()
	If $g_bStopRequested Then Return
	$g_bStopRequested = True
	State_Touch()
EndFunc   ;==>State_RequestStop

Func State_IsStopRequested()
	Return $g_bStopRequested
EndFunc   ;==>State_IsStopRequested

Func State_ClearStopRequest()
	$g_bStopRequested = False
	State_Touch()
EndFunc   ;==>State_ClearStopRequest
#EndRegion Stop request

#Region Revision and yielding
Func State_Touch()
	$g_iStateRevision += 1
EndFunc   ;==>State_Touch

Func State_GetRevision()
	Return $g_iStateRevision
EndFunc   ;==>State_GetRevision

;~ Description: Lets the host (Main.au3) repaint while a long, blocking call is
;~              in progress.
;~
;~              The controller is written as a tick machine, so this is normally
;~              unnecessary. It exists for the case where the real pathfinder or
;~              travel code you paste into the adapters blocks for several
;~              seconds: call State_Yield() inside those loops and the GUI keeps
;~              updating. It is a plain callback, so no GUI knowledge leaks in.
Func State_SetPumpHandler($sFunctionName)
	$g_sPumpHandler = $sFunctionName
EndFunc   ;==>State_SetPumpHandler

Func State_Yield($iMinIntervalMs = 50)
	If $g_sPumpHandler = "" Then Return
	If TimerDiff($g_hPumpTimer) < $iMinIntervalMs Then Return

	$g_hPumpTimer = TimerInit()
	Call($g_sPumpHandler)
EndFunc   ;==>State_Yield
#EndRegion Revision and yielding
