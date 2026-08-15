#include-once

#cs ----------------------------------------------------------------------------

    App.au3 - the application, shared by both entry points (Vanquisher.au3 for
    a real client, Simulation.au3 for none). GUI over controller over adapters;
    the loop below is the whole scheduler: one slice of bot work, one repaint,
    a short sleep.

    Command line: -character "My Character" [-autostart]

#ce ----------------------------------------------------------------------------

#include "Config.au3"
#include "Log.au3"
#include "BotState.au3"
#include "PartyConfig.au3"
#include "Maps.au3"
#include "Routes.au3"
#include "GuildWars.au3"
#include "Pathfinder.au3"
#include "BotController.au3"
#include "GUI.au3"

;~ Description: Starts the application. $bSimulation picks the adapters' mode.
Func App_Run($bSimulation)
	Opt("GUIOnEventMode", 1)     ; button clicks are delivered to handler functions
	Opt("GUICloseOnESC", False)  ; ESC must not kill a long unattended run

	OnAutoItExitRegister("App_OnExit")

	Config_ApplyMode($bSimulation)
	App_ParseCommandLine()

	VqLog_Start()
	State_Init()
	PartyConfig_Load()
	Maps_Load()

	GUI_Create()

	; Lets a blocking adapter call keep the window alive; see State_Yield().
	State_SetPumpHandler("GUI_Pump")

	VqLog_Info($VQ_BOT_TITLE & " ready. Press Start to begin.")

	If $g_bAutoStart Then
		VqLog_Status("Auto-start requested on the command line.")
		StartBot($g_sTargetCharacter)
	EndIf

	App_Loop()
EndFunc   ;==>App_Run

;~ Description: The application loop. Kept deliberately tiny - all behaviour
;~              lives in the controller, all presentation in the GUI.
Func App_Loop()
	Local $hExitTimer = 0

	While True
		Bot_Tick()
		GUI_Update()

		If GUI_IsExitRequested() Then
			If $hExitTimer = 0 Then $hExitTimer = TimerInit()

			; Normally we wait for the workflow to stop safely. The grace period
			; stops a wedged adapter from keeping the window alive forever.
			If Not Bot_IsActive() Or TimerDiff($hExitTimer) > 15000 Then ExitLoop
		EndIf

		Sleep($TICK_SLEEP_MS)
	WEnd

	Exit
EndFunc   ;==>App_Loop

;~ Description: -character "Name" selects the client, -autostart begins at once.
Func App_ParseCommandLine()
	For $i = 1 To $CmdLine[0]
		Switch $CmdLine[$i]
			Case "-character"
				If $i < $CmdLine[0] Then $g_sTargetCharacter = $CmdLine[$i + 1]
			Case "-autostart"
				$g_bAutoStart = True
		EndSwitch
	Next

	; Passing a character on its own implies "just get on with it", which is how
	; the original script behaved.
	If $g_sTargetCharacter <> "" And $CmdLine[0] = 2 Then $g_bAutoStart = True
EndFunc   ;==>App_ParseCommandLine

;~ Description: GwAu3 calls _Exit() when it cannot find the client it was asked
;~              for, so the host script has to provide one.
Func _Exit()
	Exit
EndFunc   ;==>_Exit

;~ Description: Runs on every exit, including a crash, so the log always says
;~              how the session ended.
Func App_OnExit()
	Bot_Shutdown()
	VqLog_Info("Script terminated. ExitCode=" & @exitCode)
	GUI_Shutdown()
EndFunc   ;==>App_OnExit
