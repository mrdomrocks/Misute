#RequireAdmin
#include "../../../API/_GwAu3.au3"
#include "GwAu3_AddOns.au3"

#Region Declarations

; =======================
; Globals
; =======================

Global Const $doLoadLoggedChars = True
Opt("GUIOnEventMode", 1)
Opt("GUICloseOnESC", False)
Opt("ExpandVarStrings", 1)

Global $ProcessID = ""
Global $g_b_DebugMode = False
Global Const $BotTitle = "Misute"
Global $BotRunning = False
Global $Bot_Core_Initialized = False


$g_bAutoStart = False  ; Flag for auto-start
$g_s_MainCharName  = ""

; =======================
; Logging
; =======================

Global Const $g_s_LogFile = @ScriptDir & "\console_log.txt"
FileDelete($g_s_LogFile)
OnAutoItExitRegister("_OnExitLog")

#EndRegion Declaration

#include "Farms/Farms_All.au3"

; =======================
; Command line arguments
; =======================

For $i = 1 To $CmdLine[0]
    If $CmdLine[$i] = "-character" And $i < $CmdLine[0] Then
        $g_s_MainCharName = $CmdLine[$i + 1]
        $g_bAutoStart = True
        ExitLoop
    EndIf
Next

#include "GUI.au3"

; =======================
; Startup info
; =======================

LogInfo("Based on GWA2")
LogInfo("GWA2 - Created by: " & $GC_S_GWA2_CREATOR)
LogInfo("GWA2 - Build date: " & $GC_S_GWA2_BUILD_DATE & @CRLF)
LogInfo("GwAu3 - Created by: " & $GC_S_UPDATOR)
LogInfo("GwAu3 - Build date: " & $GC_S_BUILD_DATE)
LogInfo("GwAu3 - Version: " & $GC_S_VERSION)
LogInfo("GwAu3 - Last Update: " & $GC_S_LAST_UPDATE & @CRLF)
Core_AutoStart()

While Not $BotRunning
    Sleep(100)
WEnd

While True
    If $BotRunning = True Then
        Main()
    Else
        Sleep(1000)
    EndIf
WEnd

; =======================
; Functions
; =======================

Func Main()
    Sleep(1000)
EndFunc

; =======================
; Crash Logging
; =======================

Func _OnExitLog()
    Local $code = @exitCode
    Local $msg = "Script terminated. ExitCode=" & $code
    Local $hFile = FileOpen($g_s_LogFile, $FO_APPEND)
    If $hFile <> -1 Then
        FileWrite($hFile, _
            @CRLF & "[" & @HOUR & ":" & @MIN & ":" & @SEC & "] [EXIT] " & _
            $msg)
        FileClose($hFile)
    EndIf
EndFunc
