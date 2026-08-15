#include-once
#include "Config.au3"
#include "Log.au3"
#include "BotState.au3"
#include "GuildWars.au3"
#include "Routes.au3"

#cs ----------------------------------------------------------------------------

    Pathfinder.au3 - the movement adapter around the GwAu3 pathfinder plugin.

    Three jobs cover the workflow: BeginTravel (map travel to an outpost),
    BeginTransfer (walk to a zone through portals) and BeginRoute (walk the
    zone's vanquish route). A job is started, then Pathfinder_Step() does one
    waypoint or one portal hop per call; the plugin's per-iteration callback
    keeps the window painting while a leg is walked.

    Transfers use Map_GetPathWithPortalCoords() - the exit coordinates that
    ship with the API - so one mechanism covers both walking next door and
    caravanning several zones in when the target has no outpost of its own.

#ce ----------------------------------------------------------------------------

#Region Job status
Global Const $ePATH_IDLE = 0        ; nothing running
Global Const $ePATH_RUNNING = 1     ; still working
Global Const $ePATH_COMPLETE = 2    ; arrived / route finished
Global Const $ePATH_FAILED = 3      ; could not do it
#EndRegion Job status

#Region Job types
Global Const $ePATHJOB_NONE = 0
Global Const $ePATHJOB_TRAVEL = 1   ; map travel to an outpost
Global Const $ePATHJOB_TRANSFER = 2 ; walk to a zone through portals
Global Const $ePATHJOB_ROUTE = 3    ; run the zone's vanquish route
#EndRegion Job types

#Region State
Global $g_bPathInitialised = False
Global $g_iPathStatus = $ePATH_IDLE
Global $g_iPathJob = $ePATHJOB_NONE
Global $g_sPathDescription = ""
Global $g_sPathLastError = ""
Global $g_iPathTargetMapId = 0

;~ Ranges the plugin was initialised with; the transfer job uses a tighter
;~ aggro range than the vanquish route (see Config.au3).
Global $g_iPathAggroRange = $PATH_AGGRO_RANGE

;~ Portal plan: [map id, map name, portal x, portal y] per crossed map.
Global $g_aPathPlan[0][4]
Global $g_iPathHops = 0

;~ Vanquish route waypoints and how far through them we are.
Global $g_aPathRoute[0][2]
Global $g_iPathWaypoint = 0

;~ Full party wipes survived by the current job (see Pathfinder_OnDefeat).
Global $g_iPathDeaths = 0

Global Const $ePLAN_MAP_ID = 0
Global Const $ePLAN_MAP_NAME = 1
Global Const $ePLAN_PORTAL_X = 2
Global Const $ePLAN_PORTAL_Y = 3

;~ Simulation only.
Global $g_hSimPathTimer = 0
Global $g_iSimPathDurationMs = 0
Global $g_bSimPathWillFail = False
Global $g_iSimPathHopsLeft = 0
#EndRegion State

#Region Lifecycle
;~ Description: Loads the pathfinder plugin and gives it the ranges it should
;~              work to. Called once per run.
Func Pathfinder_Init($iAggroRange = $PATH_AGGRO_RANGE)
	$g_iPathStatus = $ePATH_IDLE
	$g_iPathJob = $ePATHJOB_NONE
	$g_sPathLastError = ""
	$g_iPathAggroRange = $iAggroRange

	If $g_bSimulationMode Then
		$g_bPathInitialised = True
		Return True
	EndIf

	$DLL_PATH = @ScriptDir & $PATH_DLL_RELATIVE

	Local $iResult = Pathfinder_Initialize()
	If $iResult = 0 Then
		$g_bPathInitialised = False
		$g_sPathLastError = "GWPathfinder.dll could not be loaded from " & $DLL_PATH & "."
		Return False
	ElseIf $iResult = 2 Then
		VqLog_Warn("The pathfinder loaded but found no map data - it will download maps.rar on first use.")
	EndIf

	; Ranges: how far apart waypoints may be, when one counts as reached, and
	; how often the path and the moving obstacles are refreshed.
	Pathfinder_SetSimplifyRange($PATH_SIMPLIFY_RANGE)
	Pathfinder_SetWaypointReachedDistance($PATH_WAYPOINT_REACHED)
	Pathfinder_SetPathUpdateInterval($PATH_UPDATE_INTERVAL_MS)
	Pathfinder_SetObstacleUpdateInterval($PATH_OBSTACLE_UPDATE_MS)

	$g_bPathInitialised = True
	VqLog_Info("Pathfinder ready (aggro " & $g_iPathAggroRange & ", simplify " & $PATH_SIMPLIFY_RANGE & ").")
	Return True
EndFunc   ;==>Pathfinder_Init

Func Pathfinder_IsAvailable()
	Return $g_bPathInitialised
EndFunc   ;==>Pathfinder_IsAvailable
#EndRegion Lifecycle

#Region Jobs
;~ Description: Starts map travel to an outpost.
Func Pathfinder_BeginTravel($iOutpostId, $sOutpostName)
	Pathfinder_BeginJob($ePATHJOB_TRAVEL, "Travelling to " & $sOutpostName, $iOutpostId, $SIM_TRAVEL_MS)

	If $iOutpostId <= 0 Then
		Pathfinder_FailJob("No outpost id is known for " & $sOutpostName & ".")
		Return False
	EndIf

	GW_BeginTravel($iOutpostId)
	Return True
EndFunc   ;==>Pathfinder_BeginTravel

;~ Description: Starts walking to a zone. One portal hop when the zone is next
;~              door, a caravan across several zones when it is not.
Func Pathfinder_BeginTransfer($iMapId, $sMapName)
	Pathfinder_BeginJob($ePATHJOB_TRANSFER, "Walking to " & $sMapName, $iMapId, $SIM_PORTAL_MS)
	$g_iPathHops = 0

	If $g_bSimulationMode Then
		$g_iSimPathHopsLeft = Random(1, 3, 1)
		Return True
	EndIf

	If Not Pathfinder_BuildPlan() Then Return False
	Return True
EndFunc   ;==>Pathfinder_BeginTransfer

;~ Description: Starts (or restarts) a zone's vanquish route.
Func Pathfinder_BeginRoute($sRoute, $sMapName)
	Pathfinder_BeginJob($ePATHJOB_ROUTE, "Running the " & $sMapName & " route", 0, $SIM_ZONE_MS)
	$g_iPathWaypoint = 0

	If $g_bSimulationMode Then Return True

	$g_aPathRoute = Routes_Get($sRoute)
	If @error Or UBound($g_aPathRoute) = 0 Then
		Pathfinder_FailJob("No route data is registered under '" & $sRoute & "'.")
		Return False
	EndIf

	VqLog_Info($sMapName & " route: " & UBound($g_aPathRoute) & " waypoints.")
	Return True
EndFunc   ;==>Pathfinder_BeginRoute

;~ Description: Moves the current job on and reports where it is up to.
Func Pathfinder_Step()
	If $g_iPathStatus <> $ePATH_RUNNING Then Return $g_iPathStatus
	If $g_bSimulationMode Then Return PathfinderSim_Step()

	Switch $g_iPathJob
		Case $ePATHJOB_TRAVEL
			Return Pathfinder_StepTravel()
		Case $ePATHJOB_TRANSFER
			If GW_IsPartyDead() Then Return Pathfinder_OnDefeat()
			Return Pathfinder_StepTransfer()
		Case $ePATHJOB_ROUTE
			If GW_IsPartyDead() Then Return Pathfinder_OnDefeat()
			Return Pathfinder_StepRoute()
	EndSwitch

	Return Pathfinder_FailJob("The pathfinder was stepped with no job running.")
EndFunc   ;==>Pathfinder_Step

;~ Description: Stops the pathfinder. Called on failure, timeout and stop.
Func Pathfinder_Abort()
	If $g_iPathJob <> $ePATHJOB_NONE Then VqLog_Info("Pathfinder aborted: " & $g_sPathDescription)

	$g_iPathStatus = $ePATH_IDLE
	$g_iPathJob = $ePATHJOB_NONE
	$g_sPathDescription = ""
	$g_hSimPathTimer = 0

	; Only worth telling the character to stop if we ever told it to move.
	If Not $g_bSimulationMode And $g_bPathInitialised Then Agent_CancelAction()
	Return True
EndFunc   ;==>Pathfinder_Abort
#EndRegion Jobs

#Region Steps
;~ Description: Travel is a client operation - there is nothing to walk, we just
;~              wait for the character to appear in the outpost.
Func Pathfinder_StepTravel()
	If GW_IsInOutpost() And GW_GetCurrentMapId() = $g_iPathTargetMapId Then Return Pathfinder_CompleteJob()
	Return $ePATH_RUNNING
EndFunc   ;==>Pathfinder_StepTravel

;~ Description: One portal hop of the plan. The hop only counts when the map
;~              actually changes, which is what stops the bot pacing back and
;~              forth over a portal it never crosses.
Func Pathfinder_StepTransfer()
	Local $iCurrentMap = GW_GetCurrentMapId()

	If $iCurrentMap = $g_iPathTargetMapId And GW_IsInExplorable() Then Return Pathfinder_CompleteJob()
	If $g_iPathHops >= $MAX_PORTAL_HOPS Then Return Pathfinder_FailJob("Gave up after " & $g_iPathHops & " portal hops.")

	; Rebuild whenever we are not where the plan expects us to be: on the first
	; step, after each hop, and after any unplanned map change.
	If UBound($g_aPathPlan) = 0 Or $g_aPathPlan[0][$ePLAN_MAP_ID] <> $iCurrentMap Then
		If Not Pathfinder_BuildPlan() Then Return $ePATH_FAILED
	EndIf

	Local $fPortalX = $g_aPathPlan[0][$ePLAN_PORTAL_X]
	Local $fPortalY = $g_aPathPlan[0][$ePLAN_PORTAL_Y]
	Local $sNextName = $g_aPathPlan[1][$ePLAN_MAP_NAME]

	If $fPortalX = 0 And $fPortalY = 0 Then
		Return Pathfinder_FailJob("The API has no exit coordinates from " & _
				$g_aPathPlan[0][$ePLAN_MAP_NAME] & " to " & $sNextName & ".")
	EndIf

	State_SetActivity("Crossing into " & $sNextName)
	Pathfinder_MoveTo($fPortalX, $fPortalY, -1, $PATH_OBSTACLE_FUNC, _
			$PATH_TRANSIT_AGGRO_RANGE, $PATH_FIGHT_RANGE_OUT, 0, "Pathfinder_OnMoveTick")

	; A wipe on the way is recovered, not failed: after the shrine the next
	; step simply walks to the portal again from wherever we came back.
	If GW_IsPartyDead() Then Return Pathfinder_OnDefeat()

	; Standing on the portal is not the same as going through it.
	If GW_GetCurrentMapId() = $iCurrentMap Then Pathfinder_PushThroughPortal($fPortalX, $fPortalY, $iCurrentMap)

	If GW_GetCurrentMapId() = $iCurrentMap Then
		Return Pathfinder_FailJob("Could not cross from " & $g_aPathPlan[0][$ePLAN_MAP_NAME] & " into " & $sNextName & ".")
	EndIf

	$g_iPathHops += 1
	Pathfinder_WaitForMapLoad()
	VqLog_Status("Entered " & GW_GetMapName(GW_GetCurrentMapId()) & ".")
	Return $ePATH_RUNNING
EndFunc   ;==>Pathfinder_StepTransfer

;~ Description: One waypoint of the vanquish route. Pathfinder_MoveTo() fights
;~              everything inside the aggro range on the way, so the route is
;~              only ever "where to walk next".
Func Pathfinder_StepRoute()
	If $g_iPathWaypoint >= UBound($g_aPathRoute) Then Return Pathfinder_CompleteJob()

	Local $iMapBefore = GW_GetCurrentMapId()
	Local $fX = $g_aPathRoute[$g_iPathWaypoint][0]
	Local $fY = $g_aPathRoute[$g_iPathWaypoint][1]
	$g_iPathWaypoint += 1

	; Waypoints we are already standing on are common where routes overlap.
	If Agent_GetDistanceToXY($fX, $fY) < $PATH_WAYPOINT_SKIP_RANGE Then Return $ePATH_RUNNING

	Pathfinder_MoveTo($fX, $fY, -1, $PATH_OBSTACLE_FUNC, _
			$g_iPathAggroRange, $PATH_FIGHT_RANGE_OUT, 0, "Pathfinder_OnMoveTick")

	If GW_IsPartyDead() Then Return Pathfinder_OnDefeat()
	If GW_GetCurrentMapId() <> $iMapBefore Then Return Pathfinder_FailJob("The route left the zone unexpectedly.")

	Return $ePATH_RUNNING
EndFunc   ;==>Pathfinder_StepRoute

;~ Description: A full party wipe. The character is still lying where it died,
;~              so that position is remembered; the game then brings the party
;~              back at a resurrection shrine (usually ~15 seconds). Once back,
;~              a route rewinds to the already-visited waypoint nearest the
;~              death spot, so the pathfinder walks us from the shrine to where
;~              we died - or near enough - and the route carries on from there.
Func Pathfinder_OnDefeat()
	$g_iPathDeaths += 1
	If $g_iPathDeaths > $MAX_DEATHS_PER_JOB Then
		Return Pathfinder_FailJob("The party was wiped " & $g_iPathDeaths & " times.")
	EndIf

	Local $aDeath = GW_GetPosition()
	VqLog_Warn("The party was wiped at " & Round($aDeath[0]) & ", " & Round($aDeath[1]) & _
			" (wipe " & $g_iPathDeaths & " of " & $MAX_DEATHS_PER_JOB & ") - waiting for the shrine.")
	State_SetActivity("Waiting for the resurrection shrine")

	Local $iMapBefore = GW_GetCurrentMapId()
	Local $hTimer = TimerInit()
	While GW_IsPartyDead() Or GW_IsPlayerDead()
		If TimerDiff($hTimer) > $RESPAWN_TIMEOUT_MS Then
			Return Pathfinder_FailJob("The party did not respawn within " & ($RESPAWN_TIMEOUT_MS / 1000) & " seconds of the wipe.")
		EndIf
		If GW_GetCurrentMapId() <> $iMapBefore Then
			Return Pathfinder_FailJob("The wipe put the party out of the zone.")
		EndIf
		State_Yield()
		Sleep(250)
	WEnd

	Local $aShrine = GW_GetPosition()

	If $g_iPathJob = $ePATHJOB_ROUTE Then
		$g_iPathWaypoint = Pathfinder_NearestVisitedWaypoint($aDeath[0], $aDeath[1])
		VqLog_Status("Respawned at " & Round($aShrine[0]) & ", " & Round($aShrine[1]) & _
				" - walking back to waypoint " & ($g_iPathWaypoint + 1) & " of " & UBound($g_aPathRoute) & _
				", nearest to where we died.")
	Else
		VqLog_Status("Respawned at " & Round($aShrine[0]) & ", " & Round($aShrine[1]) & " - carrying on to the portal.")
	EndIf

	Return $ePATH_RUNNING
EndFunc   ;==>Pathfinder_OnDefeat

;~ Description: The index of the waypoint closest to a position, out of the
;~              waypoints the route has already visited. Only visited ones are
;~              considered because the concatenated routes double back on
;~              themselves - matching against the whole array could skip half
;~              the zone.
Func Pathfinder_NearestVisitedWaypoint($fX, $fY)
	Local $iLast = $g_iPathWaypoint - 1
	If $iLast > UBound($g_aPathRoute) - 1 Then $iLast = UBound($g_aPathRoute) - 1
	If $iLast < 0 Then Return 0

	Local $iNearest = 0
	Local $fNearest = -1

	For $i = 0 To $iLast
		Local $fDistance = ($g_aPathRoute[$i][0] - $fX) ^ 2 + ($g_aPathRoute[$i][1] - $fY) ^ 2
		If $fNearest < 0 Or $fDistance < $fNearest Then
			$fNearest = $fDistance
			$iNearest = $i
		EndIf
	Next

	Return $iNearest
EndFunc   ;==>Pathfinder_NearestVisitedWaypoint

;~ Description: Called by the plugin on every iteration of a move, which is what
;~              keeps the window painting while a leg is being walked.
Func Pathfinder_OnMoveTick()
	State_Yield()
EndFunc   ;==>Pathfinder_OnMoveTick
#EndRegion Steps

#Region Portal plan
;~ Description: Asks the API which maps lie between here and the target, and
;~              where the exit portal out of each of them is.
Func Pathfinder_BuildPlan()
	Local $iCurrentMap = GW_GetCurrentMapId()
	Local $aPath = Map_GetPathWithPortalCoords($iCurrentMap, $g_iPathTargetMapId)

	If Not IsArray($aPath) Or UBound($aPath) < 2 Then
		Pathfinder_FailJob("No portal path from " & GW_GetMapName($iCurrentMap) & " to " & _
				GW_GetMapName($g_iPathTargetMapId) & ".")
		Return False
	EndIf

	Local $aPlan[UBound($aPath)][4]
	For $i = 0 To UBound($aPath) - 1
		$aPlan[$i][$ePLAN_MAP_ID] = $aPath[$i][0]
		$aPlan[$i][$ePLAN_MAP_NAME] = $aPath[$i][1]
		$aPlan[$i][$ePLAN_PORTAL_X] = $aPath[$i][2]
		$aPlan[$i][$ePLAN_PORTAL_Y] = $aPath[$i][3]
	Next
	$g_aPathPlan = $aPlan

	If UBound($aPlan) > 2 Then
		VqLog_Status("Caravanning " & (UBound($aPlan) - 1) & " zones: " & Pathfinder_GetPlanText() & ".")
	EndIf
	Return True
EndFunc   ;==>Pathfinder_BuildPlan

;~ Description: "Old Ascalon > Regent Valley > Pockmark Flats", for the log.
Func Pathfinder_GetPlanText()
	Local $sText = ""
	For $i = 0 To UBound($g_aPathPlan) - 1
		If $i > 0 Then $sText &= " > "
		$sText &= $g_aPathPlan[$i][$ePLAN_MAP_NAME]
	Next
	Return $sText
EndFunc   ;==>Pathfinder_GetPlanText

;~ Description: Walks the last few steps into a portal. The pathfinder stops
;~              125 units short of its destination, which is sometimes just shy
;~              of the map line.
Func Pathfinder_PushThroughPortal($fX, $fY, $iMapBefore)
	For $i = 1 To 3
		Map_Move($fX, $fY, 0)

		Local $hTimer = TimerInit()
		While TimerDiff($hTimer) < 1500
			If GW_GetCurrentMapId() <> $iMapBefore Then Return True
			State_Yield()
			Sleep(100)
		WEnd
	Next

	Return GW_GetCurrentMapId() <> $iMapBefore
EndFunc   ;==>Pathfinder_PushThroughPortal

Func Pathfinder_WaitForMapLoad()
	Local $hTimer = TimerInit()
	While Not GW_IsMapLoaded() And TimerDiff($hTimer) < 30000
		State_Yield()
		Sleep(200)
	WEnd
EndFunc   ;==>Pathfinder_WaitForMapLoad
#EndRegion Portal plan

#Region Queries
Func Pathfinder_GetStatus()
	Return $g_iPathStatus
EndFunc   ;==>Pathfinder_GetStatus

Func Pathfinder_GetJob()
	Return $g_iPathJob
EndFunc   ;==>Pathfinder_GetJob

;~ Description: Short "what is it doing" text for the GUI/log.
Func Pathfinder_GetProgressText()
	If $g_iPathStatus <> $ePATH_RUNNING Then Return $g_sPathDescription

	Local $iPercent = Pathfinder_GetProgressPercent()
	If $iPercent < 0 Then Return $g_sPathDescription
	Return $g_sPathDescription & " (" & $iPercent & "%)"
EndFunc   ;==>Pathfinder_GetProgressText

;~ Description: Progress through the current job, or -1 when unknown.
Func Pathfinder_GetProgressPercent()
	If $g_bSimulationMode Then
		If $g_hSimPathTimer = 0 Or $g_iSimPathDurationMs <= 0 Then Return -1
		Local $iPercent = Int((TimerDiff($g_hSimPathTimer) / $g_iSimPathDurationMs) * 100)
		Return ($iPercent > 100) ? 100 : $iPercent
	EndIf

	If $g_iPathJob = $ePATHJOB_ROUTE And UBound($g_aPathRoute) > 0 Then
		Return Int(($g_iPathWaypoint / UBound($g_aPathRoute)) * 100)
	EndIf

	Return -1
EndFunc   ;==>Pathfinder_GetProgressPercent

Func Pathfinder_GetLastError()
	Return $g_sPathLastError
EndFunc   ;==>Pathfinder_GetLastError
#EndRegion Queries

#Region Internal
;~ Description: Common bookkeeping when any job starts.
Func Pathfinder_BeginJob($iJobType, $sDescription, $iTargetMapId, $iSimDurationMs)
	$g_iPathJob = $iJobType
	$g_iPathStatus = $ePATH_RUNNING
	$g_sPathDescription = $sDescription
	$g_sPathLastError = ""
	$g_iPathTargetMapId = $iTargetMapId
	$g_iPathDeaths = 0

	ReDim $g_aPathPlan[0][4]

	$g_hSimPathTimer = TimerInit()
	$g_iSimPathDurationMs = $iSimDurationMs
	$g_bSimPathWillFail = ($g_bSimulationMode And Random(1, 100, 1) <= $SIM_PATH_FAIL_PERCENT)
EndFunc   ;==>Pathfinder_BeginJob

Func Pathfinder_CompleteJob()
	$g_iPathStatus = $ePATH_COMPLETE
	Return $ePATH_COMPLETE
EndFunc   ;==>Pathfinder_CompleteJob

;~ Description: Records why a job failed and returns the failed status, so call
;~              sites can do "Return Pathfinder_FailJob(...)".
Func Pathfinder_FailJob($sReason)
	$g_sPathLastError = $sReason
	$g_iPathStatus = $ePATH_FAILED
	Return $ePATH_FAILED
EndFunc   ;==>Pathfinder_FailJob
#EndRegion Internal

#Region Simulation
;~ Description: Simulated pathfinder: jobs take a while, sometimes fail, and
;~              move the simulated character when they finish.
Func PathfinderSim_Step()
	If $g_hSimPathTimer = 0 Then Return Pathfinder_FailJob("Simulated pathfinder had no job.")

	Local $iElapsed = TimerDiff($g_hSimPathTimer)

	; A simulated failure happens part way through, like a real one would.
	If $g_bSimPathWillFail And $iElapsed > ($g_iSimPathDurationMs / 2) Then
		Return Pathfinder_FailJob("Simulated pathfinder failure during: " & $g_sPathDescription)
	EndIf

	If $iElapsed < $g_iSimPathDurationMs Then Return $ePATH_RUNNING

	Switch $g_iPathJob
		Case $ePATHJOB_TRAVEL
			GW_SimSetLocation($g_iPathTargetMapId, True)

		Case $ePATHJOB_TRANSFER
			; Every hop is one simulated portal; the last one lands in the zone.
			$g_iSimPathHopsLeft -= 1
			$g_iPathHops += 1
			If $g_iSimPathHopsLeft > 0 Then
				GW_SimSetLocation($g_iPathTargetMapId + $g_iPathHops, False)
				VqLog_Status("Caravanning through " & GW_GetMapName(GW_GetCurrentMapId()) & ".")
				$g_hSimPathTimer = TimerInit()
				Return $ePATH_RUNNING
			EndIf
			GW_SimSetLocation($g_iPathTargetMapId, False)
	EndSwitch

	Return Pathfinder_CompleteJob()
EndFunc   ;==>PathfinderSim_Step
#EndRegion Simulation
