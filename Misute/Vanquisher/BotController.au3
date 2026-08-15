#include-once
#include <Array.au3>
#include "Config.au3"
#include "Log.au3"
#include "BotState.au3"
#include "Maps.au3"
#include "GuildWars.au3"
#include "Pathfinder.au3"

#cs ----------------------------------------------------------------------------

    BotController.au3

    The bot itself: work queue, retries, the two hour per-attempt ceiling and
    the stop handling.

    It is written as a tick machine. The application loop calls Bot_Tick() over
    and over; each call does one small piece of work and returns. That is what
    keeps the GUI alive, makes the stop button responsive and lets the zone
    timer be checked continuously - no Sleep(7200000) anywhere.

    The controller knows nothing about the GUI. It publishes progress through
    BotState.au3 and text through Log.au3, and it is driven by exactly two
    public entry points:

        StartBot()      begin a run
        RequestStop()   ask the run to stop at the next safe point

    Flow of one zone:

        NEXT_MAP -> TRAVELLING -> PREPARING -> ENTERING -> VANQUISHING -> CONFIRMING
             ^                                    |            |              |
             |                                    +------------+--------------+
             +---------------------- RECOVERING <------- (failure / timeout)

    ENTERING is where caravanning happens: it walks portal to portal until it
    reaches the zone, and if it passes through another zone from the list on the
    way, that zone is vanquished first (see Bot_ClaimCurrentZone).

#ce ----------------------------------------------------------------------------

#Region State
Global $g_bBotActive = False        ; True while the tick machine has work
Global $g_aWorkQueue[0]             ; map indices still to do, in order
Global $g_iCurrentMapIndex = -1     ; zone being worked on, -1 when none

Global $g_hStepTimer = 0            ; ceiling for the current state
Global $g_bStepStarted = False      ; has this state's one-off work been done?
Global $g_hProgressLogTimer = 0     ; throttles "still vanquishing" logging
Global $g_iCheckCursor = 0          ; zone being queried during the check phase
Global $g_iRouteLoops = 0           ; route restarts within this attempt
Global $g_iLastKnownMapId = 0       ; used to notice zone changes

Global $g_iRunTotal = 0             ; zones this run set out to vanquish
Global $g_iRunVanquished = 0        ; zones vanquished during this run
#EndRegion State

#Region Public API
;~ Description: Starts a run. Called by the GUI's Start button; returns straight
;~              away, all the work happens in Bot_Tick().
Func StartBot($sCharacterName = "")
	If $g_bBotActive Then Return False

	$g_sTargetCharacter = $sCharacterName

	State_ResetForRun()
	State_ClearStopRequest()
	Maps_ResetRuntimeState()
	Bot_ClearQueue()

	$g_iCurrentMapIndex = -1
	$g_iCheckCursor = 0
	$g_iRouteLoops = 0
	$g_iRunTotal = 0
	$g_iRunVanquished = 0
	$g_iLastKnownMapId = 0
	$g_bBotActive = True

	VqLog_Event("Start requested" & (($sCharacterName <> "") ? " for " & $sCharacterName : "") & ".")
	Bot_TransitionTo($eBOT_INITIALISING)
	Return True
EndFunc   ;==>StartBot

;~ Description: Asks the workflow to stop. Nothing is torn down here - the flag
;~              is picked up by the next Bot_Tick(), which stops safely.
Func RequestStop()
	If Not $g_bBotActive Then
		State_SetBotState($eBOT_IDLE)
		State_SetStatusText("Idle")
		Return False
	EndIf

	If State_IsStopRequested() Then Return False

	State_RequestStop()
	State_SetStatusText("Stop requested...")
	VqLog_Status("Stop requested - finishing the current step first.")
	Return True
EndFunc   ;==>RequestStop

Func Bot_IsActive()
	Return $g_bBotActive
EndFunc   ;==>Bot_IsActive

Func Bot_GetQueueLength()
	Return UBound($g_aWorkQueue)
EndFunc   ;==>Bot_GetQueueLength

;~ Description: Character names for the GUI's combo box. Routed through the
;~              controller so the GUI never touches an adapter directly.
Func Bot_GetLoggedCharNames()
	Return GW_GetLoggedCharNames()
EndFunc   ;==>Bot_GetLoggedCharNames

Func Bot_SetRendering($bEnabled)
	Return GW_SetRendering($bEnabled)
EndFunc   ;==>Bot_SetRendering

;~ Description: Called once when the application closes.
Func Bot_Shutdown()
	If $g_bBotActive Then VqLog_Status("Shutting down while the bot was running.")
	Pathfinder_Abort()
	GW_Shutdown()
	$g_bBotActive = False
EndFunc   ;==>Bot_Shutdown
#EndRegion Public API

#Region Tick machine
;~ Description: One slice of bot work. Called from the application loop.
Func Bot_Tick()
	If Not $g_bBotActive Then Return

	; A stop request is honoured from whatever state we are in, as soon as the
	; current step hands control back.
	If State_IsStopRequested() And State_GetBotState() <> $eBOT_STOPPING Then
		Bot_TransitionTo($eBOT_STOPPING)
		Return
	EndIf

	Bot_CheckZoneChange()

	Switch State_GetBotState()
		Case $eBOT_INITIALISING
			Bot_TickInitialising()
		Case $eBOT_CHECKING
			Bot_TickChecking()
		Case $eBOT_NEXT_MAP
			Bot_TickNextMap()
		Case $eBOT_TRAVELLING
			Bot_TickTravelling()
		Case $eBOT_PREPARING
			Bot_TickPreparing()
		Case $eBOT_ENTERING
			Bot_TickEntering()
		Case $eBOT_VANQUISHING
			Bot_TickVanquishing()
		Case $eBOT_CONFIRMING
			Bot_TickConfirming()
		Case $eBOT_RECOVERING
			Bot_TickRecovering()
		Case $eBOT_STOPPING
			Bot_TickStopping()
		Case Else
			; Idle, finished or error: there is nothing left to drive.
			$g_bBotActive = False
	EndSwitch
EndFunc   ;==>Bot_Tick

;~ Description: Moves to another state. Resets the step timer and the "one-off
;~              work done" flag; the new state's first tick does the work, which
;~              keeps transitions from nesting inside each other.
Func Bot_TransitionTo($iState)
	State_SetBotState($iState)
	$g_hStepTimer = TimerInit()
	$g_bStepStarted = False
EndFunc   ;==>Bot_TransitionTo

;~ Description: Notices that the character is in a different area than it was on
;~              the last tick. Every explorable area the bot lands in needs its
;~              skill bar cached and its foe counters read, whether it arrived by
;~              walking, travelling or resigning.
Func Bot_CheckZoneChange()
	If Not State_IsConnected() Then Return

	Local $iMapId = GW_GetCurrentMapId()
	If $iMapId = $g_iLastKnownMapId Or $iMapId <= 0 Then Return
	If Not GW_IsMapLoaded() Then Return

	$g_iLastKnownMapId = $iMapId
	If GW_IsInExplorable() Then GW_OnZoneEntered($iMapId)
EndFunc   ;==>Bot_CheckZoneChange
#EndRegion Tick machine

#Region States
Func Bot_TickInitialising()
	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		State_SetStatusText("Initialising...")
		State_SetActivity("")
		VqLog_Status("Initialising...")
		Return
	EndIf

	; Gives the "Initialising..." line a moment on screen in simulation.
	If $g_bSimulationMode And TimerDiff($g_hStepTimer) < $SIM_CONNECT_MS Then Return

	If Not Initialise($g_sTargetCharacter) Then
		VqLog_Error("Could not attach to a Guild Wars client (error " & @error & ").")
		Bot_Fatal("Could not connect to Guild Wars.")
		Return
	EndIf

	State_SetConnected(True, GW_GetCharacterName())
	Local $sCharacter = State_GetCharacterName()
	VqLog_Event("Connected to Guild Wars" & (($sCharacter <> "") ? " as " & $sCharacter : "") & ".")

	If Not Pathfinder_Init($PATH_AGGRO_RANGE) Then
		Bot_Fatal("The pathfinder could not be initialised - " & Pathfinder_GetLastError())
		Return
	EndIf

	Bot_TransitionTo($eBOT_CHECKING)
EndFunc   ;==>Bot_TickInitialising

;~ Description: Reads the vanquished status of every zone, a couple per tick so
;~              a long map list does not freeze the display.
Func Bot_TickChecking()
	Local $iTotal = Maps_Count()

	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		$g_iCheckCursor = 0
		State_SetStatusText("Checking vanquished zones...")
		VqLog_Status("Checking vanquished zones...")

		If $iTotal = 0 Then
			VqLog_Error("The map database is empty - add zones to Maps_Load() in Maps.au3.")
			Bot_Fatal("No zones are defined.")
		EndIf
		Return
	EndIf

	If $g_bSimulationMode And TimerDiff($g_hStepTimer) < $SIM_MAP_CHECK_MS Then Return
	$g_hStepTimer = TimerInit()

	For $i = 1 To $MAPS_CHECKED_PER_TICK
		If $g_iCheckCursor >= $iTotal Then ExitLoop
		Maps_RefreshVanquishedStatus($g_iCheckCursor)
		$g_iCheckCursor += 1
	Next

	State_SetActivity("Checked " & $g_iCheckCursor & " of " & $iTotal & " zones")
	If $g_iCheckCursor < $iTotal Then Return

	$g_aWorkQueue = GetUnvanquishedMaps()
	$g_iRunTotal = UBound($g_aWorkQueue)
	Bot_UpdateCounters()

	VqLog_Info(Maps_CountByStatus($eMAPSTATUS_VANQUISHED) & " of " & $iTotal & " zones are already vanquished.")
	VqLog_Status($g_iRunTotal & " zones remaining")

	If $g_iRunTotal = 0 Then
		Bot_Finish("Nothing to do - every zone in the list is already vanquished.")
		Return
	EndIf

	Bot_TransitionTo($eBOT_NEXT_MAP)
EndFunc   ;==>Bot_TickChecking

;~ Description: Takes the next zone off the queue and starts an attempt at it.
;~              This is where the per-attempt two hour timer is started, and
;~              where the outpost to start from is worked out.
Func Bot_TickNextMap()
	If UBound($g_aWorkQueue) = 0 Then
		Bot_Finish("All zones complete.")
		Return
	EndIf

	If Not Pathfinder_IsAvailable() Then
		Bot_Fatal("The pathfinder is not available - " & Pathfinder_GetLastError())
		Return
	EndIf

	$g_iCurrentMapIndex = $g_aWorkQueue[0]
	$g_iRouteLoops = 0

	Local $sMapName = Maps_GetName($g_iCurrentMapIndex)
	Local $iMapId = Maps_GetMapId($g_iCurrentMapIndex)
	Local $iAttempt = Maps_IncrementAttempts($g_iCurrentMapIndex)

	; The starting outpost is whatever this character has unlocked nearest to
	; the zone, so a zone with no outpost of its own simply produces a longer
	; walk in rather than a special case.
	Local $iOutpost = GW_FindStartOutpost($iMapId)
	If @error Or $iOutpost <= 0 Then
		Maps_SetStatus($g_iCurrentMapIndex, $eMAPSTATUS_FAILED)
		Bot_RemoveFromQueue($g_iCurrentMapIndex)
		Maps_SetLastResult($g_iCurrentMapIndex, "No unlocked outpost leads to this zone")
		VqLog_Error($sMapName & " cannot be reached from any unlocked outpost - skipping it.")
		$g_iCurrentMapIndex = -1
		Bot_UpdateCounters()
		Return
	EndIf

	Maps_SetOutpost($g_iCurrentMapIndex, $iOutpost, GW_GetMapName($iOutpost))
	Maps_SetPartySize($g_iCurrentMapIndex, GW_GetMaxPartySize($iMapId))
	Maps_SetStatus($g_iCurrentMapIndex, $eMAPSTATUS_ACTIVE)

	State_SetCurrentMap($sMapName, Maps_GetOutpostName($g_iCurrentMapIndex))
	State_SetAttempt($iAttempt, $MAX_RETRIES)
	State_StartZoneTimer()

	VqLog_Event("Starting " & $sMapName & " (attempt " & $iAttempt & " of " & $MAX_RETRIES & ", " & _
			State_FormatDuration($g_iZoneTimeoutMs) & " allowed).")

	Bot_TransitionTo($eBOT_TRAVELLING)
EndFunc   ;==>Bot_TickNextMap

;~ Description: Gets to the outpost the attempt starts from - unless we are
;~              already out in the world and can simply walk there, which is how
;~              a caravan carries on from one zone to the next.
Func Bot_TickTravelling()
	If Bot_CheckZoneTimeout() Then Return

	Local $sOutpost = Maps_GetOutpostName($g_iCurrentMapIndex)
	Local $iOutpostId = Maps_GetOutpostId($g_iCurrentMapIndex)

	If Not $g_bStepStarted Then
		$g_bStepStarted = True

		If $CARAVAN_ENABLED And GW_IsInExplorable() And GW_CanWalkTo(Maps_GetMapId($g_iCurrentMapIndex)) Then
			VqLog_Status("Already in the field - walking on to " & Maps_GetName($g_iCurrentMapIndex) & ".")
			Bot_TransitionTo($eBOT_ENTERING)
			Return
		EndIf

		If GW_IsInOutpost() And GW_GetCurrentMapId() = $iOutpostId Then
			Bot_TransitionTo($eBOT_PREPARING)
			Return
		EndIf

		State_SetStatusText("Travelling to " & $sOutpost)
		VqLog_Status("Travelling to " & $sOutpost)
		If Not Pathfinder_BeginTravel($iOutpostId, $sOutpost) Then
			Bot_AttemptFailed("Could not start travelling to " & $sOutpost & " - " & Pathfinder_GetLastError())
		EndIf
		Return
	EndIf

	State_SetActivity(Pathfinder_GetProgressText())

	Switch Pathfinder_Step()
		Case $ePATH_COMPLETE
			VqLog_Status("Arrived at " & $sOutpost & ".")
			Bot_TransitionTo($eBOT_PREPARING)
		Case $ePATH_FAILED
			Bot_AttemptFailed("Could not travel to " & $sOutpost & " - " & Pathfinder_GetLastError())
		Case Else
			If TimerDiff($g_hStepTimer) >= $TRAVEL_TIMEOUT_MS Then
				Bot_AttemptFailed("Timed out travelling to " & $sOutpost & " after " & _
						State_FormatDuration($TRAVEL_TIMEOUT_MS) & ".")
			EndIf
	EndSwitch
EndFunc   ;==>Bot_TickTravelling

;~ Description: Sets hard mode and fills the party from Vanquisher.ini for this
;~              area's size. Both are outpost-only operations, which is why they
;~              have a step of their own between travelling and walking out.
Func Bot_TickPreparing()
	If Bot_CheckZoneTimeout() Then Return

	Local $iPartySize = Maps_GetPartySize($g_iCurrentMapIndex)

	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		State_SetStatusText("Forming the party")
		State_SetActivity($iPartySize & " man area")
		Return
	EndIf

	If $g_bSimulationMode And TimerDiff($g_hStepTimer) < $SIM_PREPARE_MS Then Return

	If Not GW_SetHardMode() Then
		Bot_AttemptFailed("Hard mode could not be set, so a vanquish would not count.")
		Return
	EndIf

	If Not GW_FormParty($iPartySize) Then
		If TimerDiff($g_hStepTimer) < $PREPARE_TIMEOUT_MS Then Return
		Bot_AttemptFailed("The " & $iPartySize & " man party could not be formed.")
		Return
	EndIf

	Bot_TransitionTo($eBOT_ENTERING)
EndFunc   ;==>Bot_TickPreparing

;~ Description: Walks from wherever we are to the zone, through as many portals
;~              as that takes. Zones from the list that are crossed on the way
;~              are claimed and vanquished first.
Func Bot_TickEntering()
	If Bot_CheckZoneTimeout() Then Return

	Local $sMapName = Maps_GetName($g_iCurrentMapIndex)

	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		State_SetStatusText("Walking to " & $sMapName)
		VqLog_Status("Heading for " & $sMapName)
		If Not Pathfinder_BeginTransfer(Maps_GetMapId($g_iCurrentMapIndex), $sMapName) Then
			Bot_AttemptFailed("Could not work out a way into " & $sMapName & " - " & Pathfinder_GetLastError())
		EndIf
		Return
	EndIf

	State_SetActivity(Pathfinder_GetProgressText())

	Switch Pathfinder_Step()
		Case $ePATH_COMPLETE
			Bot_TransitionTo($eBOT_VANQUISHING)

		Case $ePATH_FAILED
			Bot_AttemptFailed("Could not reach " & $sMapName & " - " & Pathfinder_GetLastError())

		Case Else
			If GW_IsPartyDead() Then
				Bot_AttemptFailed("The party was defeated on the way to " & $sMapName & ".")
				Return
			EndIf

			; A zone we are only passing through still counts if it is on the
			; list, and clearing it now saves walking back to it later.
			If $CARAVAN_ENABLED Then Bot_ClaimCurrentZone()

			If TimerDiff($g_hStepTimer) >= $ENTER_ZONE_TIMEOUT_MS Then
				Bot_AttemptFailed("Timed out walking to " & $sMapName & ".")
			EndIf
	EndSwitch
EndFunc   ;==>Bot_TickEntering

Func Bot_TickVanquishing()
	If Bot_CheckZoneTimeout() Then Return

	Local $sMapName = Maps_GetName($g_iCurrentMapIndex)

	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		$g_hProgressLogTimer = TimerInit()
		GW_BeginZoneAttempt(Maps_GetMapId($g_iCurrentMapIndex), $sMapName)

		; Walking into an instance that is already empty happens often enough
		; while caravanning to be worth checking before starting a route.
		If GW_IsZoneAlreadyClear() Then
			VqLog_Info($sMapName & " was already clear on entry.")
			Bot_TransitionTo($eBOT_CONFIRMING)
			Return
		EndIf

		VqLog_Event("Vanquishing " & $sMapName)
		If Not VanquishZone($g_iCurrentMapIndex) Then
			Bot_AttemptFailed("Could not start the " & $sMapName & " route - " & Pathfinder_GetLastError())
		EndIf
		Return
	EndIf

	; The zone can be finished at any point during the route.
	If IsZoneVanquished($g_iCurrentMapIndex) Then
		Pathfinder_Abort()
		Bot_TransitionTo($eBOT_CONFIRMING)
		Return
	EndIf

	Bot_UpdateVanquishActivity()

	Switch Pathfinder_Step()
		Case $ePATH_COMPLETE
			$g_iRouteLoops += 1
			If $g_iRouteLoops >= $MAX_ROUTE_LOOPS Then
				Bot_AttemptFailed("Ran the " & $sMapName & " route " & $g_iRouteLoops & " times and the zone is still not vanquished.")
				Return
			EndIf

			VqLog_Warn("The route finished but " & $sMapName & " is not vanquished - running it again (" & _
					($g_iRouteLoops + 1) & " of " & $MAX_ROUTE_LOOPS & ").")
			If Not VanquishZone($g_iCurrentMapIndex) Then
				Bot_AttemptFailed("Could not restart the " & $sMapName & " route - " & Pathfinder_GetLastError())
			EndIf

		Case $ePATH_FAILED
			Bot_AttemptFailed("Pathfinder failed in " & $sMapName & " - " & Pathfinder_GetLastError())

		Case Else
			If GW_IsPartyDead() Then Bot_AttemptFailed("The party died in " & $sMapName & ".")
	EndSwitch
EndFunc   ;==>Bot_TickVanquishing

;~ Description: Double checks the vanquish before the zone is ticked off, so a
;~              one-off bad read cannot mark a zone complete by accident.
Func Bot_TickConfirming()
	Local $sMapName = Maps_GetName($g_iCurrentMapIndex)

	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		State_SetStatusText("Confirming " & $sMapName)
		State_SetActivity("Confirming the vanquish")
		Return
	EndIf

	If IsZoneVanquished($g_iCurrentMapIndex) Or GW_IsZoneAlreadyClear() Then
		Bot_MapSucceeded()
		Return
	EndIf

	If TimerDiff($g_hStepTimer) >= $CONFIRM_TIMEOUT_MS Then
		Bot_AttemptFailed("Could not confirm that " & $sMapName & " was vanquished.")
	EndIf
EndFunc   ;==>Bot_TickConfirming

;~ Description: Gets back to a known safe state after a failure or timeout, so
;~              the next zone does not start from the middle of a zone.
Func Bot_TickRecovering()
	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		State_SetStatusText("Recovering...")
		State_SetActivity("Returning to an outpost")
		VqLog_Status("Returning to an outpost before the next zone.")
		Pathfinder_Abort()
		GW_ReturnToOutpost()
		Return
	EndIf

	If GW_IsInOutpost() Then
		Bot_TransitionTo($eBOT_NEXT_MAP)
		Return
	EndIf

	If TimerDiff($g_hStepTimer) >= $RECOVER_TIMEOUT_MS Then
		VqLog_Warn("Recovery timed out after " & State_FormatDuration($RECOVER_TIMEOUT_MS) & " - carrying on with the next zone.")
		Bot_TransitionTo($eBOT_NEXT_MAP)
	EndIf
EndFunc   ;==>Bot_TickRecovering

;~ Description: Honours a stop request: stops the pathfinder, hands the current
;~              zone back to the queue and returns the bot to idle. The GUI stays
;~              open and can start again straight away.
Func Bot_TickStopping()
	If Not $g_bStepStarted Then
		$g_bStepStarted = True
		State_SetStatusText("Stopping...")
		VqLog_Status("Stopping the workflow...")
		Pathfinder_Abort()

		If Maps_IsValidIndex($g_iCurrentMapIndex) And Maps_GetStatus($g_iCurrentMapIndex) = $eMAPSTATUS_ACTIVE Then
			Maps_SetStatus($g_iCurrentMapIndex, $eMAPSTATUS_PENDING)
			Maps_SetLastResult($g_iCurrentMapIndex, "Stopped by the user")
		EndIf
		Return
	EndIf

	; Small grace period so the adapters can settle before we go idle.
	If TimerDiff($g_hStepTimer) < 500 Then Return

	Local $iOutstanding = UBound($g_aWorkQueue)

	$g_iCurrentMapIndex = -1
	State_ClearZoneTimer()
	State_ClearCurrentMap()
	State_SetActivity("")
	State_StopRunTimer()
	State_ClearStopRequest()
	$g_bBotActive = False

	Bot_UpdateCounters()
	State_SetBotState($eBOT_IDLE)
	State_SetStatusText("Stopped")
	VqLog_Event("Bot stopped. " & $iOutstanding & " zone(s) were still outstanding.")
EndFunc   ;==>Bot_TickStopping
#EndRegion States

#Region Caravanning
;~ Description: While walking to a zone the party crosses others. If one of them
;~              is on the list and still needs doing, it becomes the zone we are
;~              working on and the original target goes back in the queue - it is
;~              on the far side of here anyway, so nothing is lost.
Func Bot_ClaimCurrentZone()
	If Not GW_IsInExplorable() Then Return False

	Local $iIndex = Maps_FindByMapId(GW_GetCurrentMapId())
	If $iIndex < 0 Or $iIndex = $g_iCurrentMapIndex Then Return False
	If Maps_GetStatus($iIndex) <> $eMAPSTATUS_PENDING Then Return False

	Local $iPrevious = $g_iCurrentMapIndex
	If Not Maps_IsValidIndex($iPrevious) Then Return False

	Pathfinder_Abort()

	Maps_SetStatus($iPrevious, $eMAPSTATUS_PENDING)
	Maps_SetLastResult($iPrevious, "Postponed - vanquishing " & Maps_GetName($iIndex) & " on the way")
	Bot_MoveToBackOfQueue($iPrevious)

	$g_iCurrentMapIndex = $iIndex
	$g_iRouteLoops = 0
	Maps_SetStatus($iIndex, $eMAPSTATUS_ACTIVE)
	Maps_IncrementAttempts($iIndex)
	Maps_SetPartySize($iIndex, GW_GetMaxPartySize(Maps_GetMapId($iIndex)))

	; The party is already formed for the outpost we came from, and that is the
	; outpost this attempt would recover to.
	Maps_SetOutpost($iIndex, Maps_GetOutpostId($iPrevious), Maps_GetOutpostName($iPrevious))

	State_SetCurrentMap(Maps_GetName($iIndex), Maps_GetOutpostName($iIndex))
	State_SetAttempt(Maps_GetAttempts($iIndex), $MAX_RETRIES)
	State_StartZoneTimer()

	VqLog_Event("Caravan: " & Maps_GetName($iIndex) & " is on the way and still needs doing - vanquishing it now.")
	Bot_TransitionTo($eBOT_VANQUISHING)
	Return True
EndFunc   ;==>Bot_ClaimCurrentZone
#EndRegion Caravanning

#Region Outcomes
;~ Description: A zone is confirmed done: tick it off, update the counters and
;~              move on (or finish if that was the last one).
Func Bot_MapSucceeded()
	Local $iIndex = $g_iCurrentMapIndex
	Local $sMapName = Maps_GetName($iIndex)

	Maps_SetStatus($iIndex, $eMAPSTATUS_VANQUISHED)
	Maps_SetLastResult($iIndex, "Vanquished in " & State_FormatDuration(State_GetZoneElapsedMs()))
	Bot_RemoveFromQueue($iIndex)
	$g_iRunVanquished += 1

	State_ClearZoneTimer()
	State_ClearCurrentMap()
	State_SetActivity("")
	$g_iCurrentMapIndex = -1

	VqLog_Event($sMapName & " successfully vanquished")
	Bot_UpdateCounters()
	VqLog_Status(UBound($g_aWorkQueue) & " zones remaining")

	If UBound($g_aWorkQueue) = 0 Then
		Bot_Finish("All zones complete.")
	Else
		Bot_TransitionTo($eBOT_NEXT_MAP)
	EndIf
EndFunc   ;==>Bot_MapSucceeded

;~ Description: The single place an attempt can fail. Decides between another
;~              attempt and giving up on the zone, then goes off to recover.
;~              Every failure path (pathfinder, timeout, unexpected state) ends
;~              up here, which is what stops the bot looping forever.
Func Bot_AttemptFailed($sReason)
	Local $iIndex = $g_iCurrentMapIndex

	VqLog_Warn($sReason)
	Pathfinder_Abort()
	State_ClearZoneTimer()
	State_SetActivity("")

	If Not Maps_IsValidIndex($iIndex) Then
		Bot_TransitionTo($eBOT_RECOVERING)
		Return
	EndIf

	Local $sMapName = Maps_GetName($iIndex)
	Local $iAttempts = Maps_GetAttempts($iIndex)
	Maps_SetLastResult($iIndex, $sReason)

	If $iAttempts >= $MAX_RETRIES Then
		Maps_SetStatus($iIndex, $eMAPSTATUS_FAILED)
		Bot_RemoveFromQueue($iIndex)
		VqLog_Error($sMapName & " failed after " & $iAttempts & " attempt(s) - marking it as failed and moving on.")
	Else
		Maps_SetStatus($iIndex, $eMAPSTATUS_PENDING)
		If $RETRY_AT_END_OF_QUEUE Then Bot_MoveToBackOfQueue($iIndex)
		VqLog_Status("Will retry " & $sMapName & " (" & ($MAX_RETRIES - $iAttempts) & " attempt(s) left).")
	EndIf

	$g_iCurrentMapIndex = -1
	State_ClearCurrentMap()
	Bot_UpdateCounters()
	Bot_TransitionTo($eBOT_RECOVERING)
EndFunc   ;==>Bot_AttemptFailed

;~ Description: The queue is empty (or there was never anything to do).
Func Bot_Finish($sReason)
	Pathfinder_Abort()
	State_ClearZoneTimer()
	State_ClearCurrentMap()
	State_SetActivity("")
	State_StopRunTimer()
	$g_iCurrentMapIndex = -1
	$g_bBotActive = False

	Bot_UpdateCounters()
	State_SetBotState($eBOT_FINISHED)
	State_SetStatusText("Finished")

	VqLog_Event($sReason)
	VqLog_Event("Run finished: " & $g_iRunVanquished & " vanquished, " & _
			Maps_CountByStatus($eMAPSTATUS_FAILED) & " failed, run time " & _
			State_FormatDuration(State_GetRunElapsedMs()) & ".")
EndFunc   ;==>Bot_Finish

;~ Description: Something the bot cannot recover from on its own. The GUI stays
;~              open, the log explains what happened and Start works again.
Func Bot_Fatal($sReason)
	Pathfinder_Abort()
	State_ClearZoneTimer()
	State_ClearCurrentMap()
	State_SetActivity("")
	State_StopRunTimer()
	$g_iCurrentMapIndex = -1
	$g_bBotActive = False

	State_SetBotState($eBOT_ERROR)
	State_SetStatusText("Error - see the log")
	VqLog_Error($sReason)
EndFunc   ;==>Bot_Fatal
#EndRegion Outcomes

#Region Workflow steps
;~ Description: Starts (or restarts) the zone's vanquish route.
Func VanquishZone($iMapIndex)
	State_SetStatusText("Vanquishing " & Maps_GetName($iMapIndex))
	Return Pathfinder_BeginRoute(Maps_GetRoute($iMapIndex), Maps_GetName($iMapIndex))
EndFunc   ;==>VanquishZone

;~ Description: Is the zone we are standing in vanquished?
Func IsZoneVanquished($iMapIndex = -1)
	Local $bVanquished = GW_IsCurrentZoneVanquished()
	If @error Then Return False
	Return $bVanquished
EndFunc   ;==>IsZoneVanquished
#EndRegion Workflow steps

#Region Helpers
;~ Description: The two hour rule. Checked on every tick of every state inside an
;~              attempt, so the bot can never sit in one zone longer than the
;~              allowance no matter where it got stuck.
Func Bot_CheckZoneTimeout()
	If Not State_IsZoneTimerRunning() Then Return False
	If Not State_HasZoneTimedOut() Then Return False

	Local $sMapName = (Maps_IsValidIndex($g_iCurrentMapIndex)) ? Maps_GetName($g_iCurrentMapIndex) : "the current zone"
	VqLog_Error("Zone timeout: " & $sMapName & " used its whole " & State_FormatDuration($g_iZoneTimeoutMs) & " allowance.")
	Bot_AttemptFailed("Timed out on " & $sMapName & " after " & State_FormatDuration(State_GetZoneElapsedMs()) & ".")
	Return True
EndFunc   ;==>Bot_CheckZoneTimeout

;~ Description: Keeps the GUI's activity line current and writes a throttled
;~              progress line to the log.
Func Bot_UpdateVanquishActivity()
	Local $iFoes = GW_GetFoesRemaining()
	Local $sActivity = Pathfinder_GetProgressText()
	If $iFoes >= 0 Then $sActivity = $iFoes & " foes remaining - " & $sActivity
	State_SetActivity($sActivity)

	If TimerDiff($g_hProgressLogTimer) < $g_iProgressLogIntervalMs Then Return
	$g_hProgressLogTimer = TimerInit()

	Local $sMapName = Maps_GetName($g_iCurrentMapIndex)
	If $iFoes >= 0 Then
		VqLog_Info("Vanquishing " & $sMapName & " - " & $iFoes & " foes remaining (" & _
				State_FormatDuration(State_GetZoneElapsedMs()) & " into the attempt).")
	Else
		VqLog_Info("Vanquishing " & $sMapName & " - " & $sActivity)
	EndIf
EndFunc   ;==>Bot_UpdateVanquishActivity

Func Bot_UpdateCounters()
	State_SetCounters($g_iRunTotal, UBound($g_aWorkQueue), $g_iRunVanquished, Maps_CountByStatus($eMAPSTATUS_FAILED))
EndFunc   ;==>Bot_UpdateCounters
#EndRegion Helpers

#Region Work queue
;~ The queue is a plain array of indices into the map database, worked from the
;~ front. A zone leaves the queue when it is vanquished or finally fails.

Func Bot_ClearQueue()
	ReDim $g_aWorkQueue[0]
EndFunc   ;==>Bot_ClearQueue

Func Bot_RemoveFromQueue($iMapIndex)
	Local $iPosition = _ArraySearch($g_aWorkQueue, $iMapIndex)
	If $iPosition < 0 Then Return False

	_ArrayDelete($g_aWorkQueue, $iPosition)
	Return True
EndFunc   ;==>Bot_RemoveFromQueue

;~ Description: Sends a zone to the back of the queue so a retry does not block
;~              every other zone behind it.
Func Bot_MoveToBackOfQueue($iMapIndex)
	If Not Bot_RemoveFromQueue($iMapIndex) Then Return False
	_ArrayAdd($g_aWorkQueue, $iMapIndex)
	Return True
EndFunc   ;==>Bot_MoveToBackOfQueue
#EndRegion Work queue
