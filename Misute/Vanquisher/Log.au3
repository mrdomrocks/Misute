#include-once
#include <FileConstants.au3>
#include "Config.au3"

#cs ----------------------------------------------------------------------------

    Log.au3 - central logging. The bot calls the VqLog_* helpers and never
    touches a GUI control; a display registers a sink callback and can replay
    the last $LOG_RING_SIZE lines. Named VqLog_* because GwAu3 already defines
    Log_Info() and Log_Error().

#ce ----------------------------------------------------------------------------

#Region Levels
Global Const $eLOG_INFO = 0     ; general chatter
Global Const $eLOG_STATUS = 1   ; workflow progress the user cares about
Global Const $eLOG_EVENT = 2    ; milestones (zone started/finished)
Global Const $eLOG_WARN = 3     ; recoverable problem, a retry is coming
Global Const $eLOG_ERROR = 4    ; gave up on something
#EndRegion Levels

#Region State
Global $g_sLogSink = ""                      ; name of the display callback
Global $g_aLogRing[$LOG_RING_SIZE][2]        ; [line, level]
Global $g_iLogRingCount = 0                  ; lines currently held
Global $g_iLogRingHead = 0                   ; next slot to write
Global $g_bLogInSink = False                 ; guards against sink recursion
#EndRegion State

#Region Public API
;~ Description: Registers the function that displays log lines.
;~              Signature of the callback: Func MySink($sLine, $iLevel)
Func VqLog_RegisterSink($sFunctionName)
	$g_sLogSink = $sFunctionName
EndFunc   ;==>VqLog_RegisterSink

;~ Description: Removes the current display callback (used on shutdown).
Func VqLog_ClearSink()
	$g_sLogSink = ""
EndFunc   ;==>VqLog_ClearSink

;~ Description: Writes a line to the log file, the in-memory ring buffer and the
;~              registered display.
Func VqLog_Write($sText, $iLevel = $eLOG_INFO)
	Local $sLine = "[" & VqLog_TimeStamp() & "] [" & VqLog_LevelName($iLevel) & "] " & $sText

	VqLog_RingAdd($sLine, $iLevel)
	VqLog_WriteToFile($sLine)

	; A sink that logs would otherwise recurse forever.
	If $g_sLogSink <> "" And Not $g_bLogInSink Then
		$g_bLogInSink = True
		Call($g_sLogSink, $sLine, $iLevel)
		$g_bLogInSink = False
	EndIf

	Return $sLine
EndFunc   ;==>VqLog_Write

Func VqLog_Info($sText)
	Return VqLog_Write($sText, $eLOG_INFO)
EndFunc   ;==>VqLog_Info

Func VqLog_Status($sText)
	Return VqLog_Write($sText, $eLOG_STATUS)
EndFunc   ;==>VqLog_Status

Func VqLog_Event($sText)
	Return VqLog_Write($sText, $eLOG_EVENT)
EndFunc   ;==>VqLog_Event

Func VqLog_Warn($sText)
	Return VqLog_Write($sText, $eLOG_WARN)
EndFunc   ;==>VqLog_Warn

Func VqLog_Error($sText)
	Return VqLog_Write($sText, $eLOG_ERROR)
EndFunc   ;==>VqLog_Error

;~ Description: Replays the buffered history into a display callback. Called by
;~              the GUI right after it registers itself.
Func VqLog_ReplayTo($sFunctionName)
	If $sFunctionName = "" Then Return
	If $g_iLogRingCount = 0 Then Return

	Local $iStart = $g_iLogRingHead - $g_iLogRingCount
	If $iStart < 0 Then $iStart += $LOG_RING_SIZE

	For $i = 0 To $g_iLogRingCount - 1
		Local $iSlot = Mod($iStart + $i, $LOG_RING_SIZE)
		Call($sFunctionName, $g_aLogRing[$iSlot][0], $g_aLogRing[$iSlot][1])
	Next
EndFunc   ;==>VqLog_ReplayTo

Func VqLog_LevelName($iLevel)
	Switch $iLevel
		Case $eLOG_STATUS
			Return "STATUS"
		Case $eLOG_EVENT
			Return "EVENT"
		Case $eLOG_WARN
			Return "WARN"
		Case $eLOG_ERROR
			Return "ERROR"
		Case Else
			Return "INFO"
	EndSwitch
EndFunc   ;==>VqLog_LevelName

;~ Description: Colour used by a rich edit display for each level.
Func VqLog_LevelColour($iLevel)
	Switch $iLevel
		Case $eLOG_ERROR
			Return 0x322CCA ; red   (BGR)
		Case $eLOG_WARN
			Return 0x790984 ; purple
		Case $eLOG_STATUS
			Return 0xC76D09 ; orange/blue-ish, matches the original console
		Case $eLOG_EVENT
			Return 0x1C7A1C ; green
		Case Else
			Return 0x000000 ; black
	EndSwitch
EndFunc   ;==>VqLog_LevelColour

Func VqLog_TimeStamp()
	Return @HOUR & ":" & @MIN & ":" & @SEC
EndFunc   ;==>VqLog_TimeStamp

;~ Description: The console hook GwAu3 and its pathfinder plugin write to. The
;~              API calls Out() rather than owning a logger, so providing it
;~              here puts API chatter in the same file and window as ours.
Func Out($sText)
	Return VqLog_Write($sText, $eLOG_INFO)
EndFunc   ;==>Out

;~ Description: Starts a fresh log file and records the header.
Func VqLog_Start()
	FileDelete($VQ_LOG_FILE)
	VqLog_Write($VQ_BOT_TITLE & " " & $VQ_BOT_VERSION & " - log started " & @YEAR & "-" & @MON & "-" & @MDAY, $eLOG_INFO)
	If $g_bSimulationMode Then
		VqLog_Write("Simulation mode is ON - no Guild Wars client is being used.", $eLOG_WARN)
	EndIf
EndFunc   ;==>VqLog_Start
#EndRegion Public API

#Region Internal
Func VqLog_RingAdd($sLine, $iLevel)
	$g_aLogRing[$g_iLogRingHead][0] = $sLine
	$g_aLogRing[$g_iLogRingHead][1] = $iLevel

	$g_iLogRingHead = Mod($g_iLogRingHead + 1, $LOG_RING_SIZE)
	If $g_iLogRingCount < $LOG_RING_SIZE Then $g_iLogRingCount += 1
EndFunc   ;==>VqLog_RingAdd

;~ Description: Appends to the log file, reopening every time so the file
;~              survives a crash of the script.
Func VqLog_WriteToFile($sLine)
	Local $hFile = FileOpen($VQ_LOG_FILE, $FO_APPEND)
	If $hFile = -1 Then Return False

	FileWriteLine($hFile, $sLine)
	FileClose($hFile)
	Return True
EndFunc   ;==>VqLog_WriteToFile
#EndRegion Internal
