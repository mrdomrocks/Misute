#include-once
#include "Config.au3"
#include "Log.au3"
#include "BotState.au3"
#include "PartyConfig.au3"

#cs ----------------------------------------------------------------------------

    GuildWars.au3 - the game adapter. Everything the bot asks of the client
    goes through here; the controller never touches the API. Every function is
    "If $g_bSimulationMode Then Return <a believable answer>" followed by the
    GwAu3 call, which is what lets Simulation.au3 run the whole application
    with no client attached. The API itself is included by Vanquisher.au3.

#ce ----------------------------------------------------------------------------

#Region Errors
Global Const $eGW_ERR_NOT_CONNECTED = 2     ; asked something before connecting
#EndRegion Errors

#Region State
;~ Foe counts as they were when the current zone was entered. A zone counts as
;~ vanquished when nothing is left to kill *and* we did some of the killing -
;~ without the second half, walking into an already-cleared instance would look
;~ like a fresh vanquish.
Global $g_iZoneBaselineFoes = 0
Global $g_iZoneBaselineKills = 0
Global $g_iZoneBaselineMapId = 0

;~ Set while looking up a henchman by player number (GetAgents() filters are
;~ plain function names, so the wanted value has to travel in a global).
Global $g_iWantedPlayerNumber = 0
#EndRegion State

#Region Simulation state
Global $g_bSimConnected = False
Global $g_iSimMapId = 0
Global $g_bSimInOutpost = True
Global $g_hSimZoneTimer = 0
Global $g_bSimZoneDoomed = False       ; this attempt will never finish
Global $g_iSimZoneFoes = 0
#EndRegion Simulation state

#Region Connection
;~ Description: Connects to the Guild Wars client. Called once per run from the
;~              controller's INITIALISING state.
Func Initialise($sCharacterName = "")
	If $g_bSimulationMode Then
		$g_bSimConnected = True
		$g_iSimMapId = 0
		$g_bSimInOutpost = True
		Return True
	EndIf

	Local $iResult
	If $sCharacterName = "" Then
		$iResult = Core_Initialize(ProcessExists("gw.exe"), True)
	Else
		$iResult = Core_Initialize($sCharacterName, True)
	EndIf

	If $iResult = 0 Then Return SetError($eGW_ERR_NOT_CONNECTED, 0, False)
	Return True
EndFunc   ;==>Initialise

Func GW_Shutdown()
	If $g_bSimulationMode Then
		$g_bSimConnected = False
		Return True
	EndIf

	Return True
EndFunc   ;==>GW_Shutdown

Func GW_IsConnected()
	If $g_bSimulationMode Then Return $g_bSimConnected
	Return Map_GetMapID() > 0
EndFunc   ;==>GW_IsConnected

Func GW_GetCharacterName()
	If $g_bSimulationMode Then
		Return ($g_sTargetCharacter <> "") ? $g_sTargetCharacter : "Simulated Hero"
	EndIf

	Return Player_GetCharName()
EndFunc   ;==>GW_GetCharacterName

;~ Description: Pipe separated character names for the GUI combo box.
Func GW_GetLoggedCharNames()
	If $g_bSimulationMode Then Return "Simulated Hero|Test Dummy"
	Return Scanner_GetLoggedCharNames()
EndFunc   ;==>GW_GetLoggedCharNames

;~ Description: Turns the client's rendering on/off to save CPU while botting.
Func GW_SetRendering($bEnabled)
	If $g_bSimulationMode Then
		VqLog_Info("Rendering would now be " & (($bEnabled) ? "enabled" : "disabled") & ".")
		Return True
	EndIf

	If $bEnabled Then
		Ui_EnableRendering()
	Else
		Ui_DisableRendering()
	EndIf
	Return True
EndFunc   ;==>GW_SetRendering
#EndRegion Connection

#Region Location
Func GW_GetCurrentMapId()
	If $g_bSimulationMode Then Return $g_iSimMapId
	Return Map_GetMapID()
EndFunc   ;==>GW_GetCurrentMapId

Func GW_IsInOutpost()
	If $g_bSimulationMode Then Return $g_bSimInOutpost
	Return Map_GetInstanceInfo("IsOutpost")
EndFunc   ;==>GW_IsInOutpost

Func GW_IsInExplorable()
	If $g_bSimulationMode Then Return Not $g_bSimInOutpost
	Return Map_GetInstanceInfo("IsExplorable")
EndFunc   ;==>GW_IsInExplorable

Func GW_IsMapLoaded()
	If $g_bSimulationMode Then Return True
	If Map_GetInstanceInfo("IsLoading") Then Return False
	Return Map_GetMapID() > 0
EndFunc   ;==>GW_IsMapLoaded

;~ Description: The map's name as the client knows it, for the log. Used for
;~              zones the bot only passes through, which are not in Maps.au3.
Func GW_GetMapName($iMapId)
	If $g_bSimulationMode Then Return "map " & $iMapId
	If $iMapId <= 0 Or $iMapId > UBound($g_a2D_MapArray) Then Return "map " & $iMapId
	Return $g_a2D_MapArray[$iMapId - 1][1]
EndFunc   ;==>GW_GetMapName

;~ Description: How many characters the area allows, which decides which team
;~ from Vanquisher.ini is used. Rounded to the sizes the game actually uses.
Func GW_GetMaxPartySize($iMapId)
	If $g_bSimulationMode Then Return 8

	Local $iSize = Map_GetAreaInfo($iMapId, "MaxPartySize")
	If $iSize <= 0 Then $iSize = Map_GetAreaInfo(Map_GetAreaInfo($iMapId, "ControlledOutpostID"), "MaxPartySize")

	If $iSize <= 0 Then Return 8
	If $iSize <= 4 Then Return 4
	If $iSize <= 6 Then Return 6
	Return 8
EndFunc   ;==>GW_GetMaxPartySize

;~ Description: The outpost a run at $iMapId should start from: the nearest one
;~              this character has unlocked. Zones without an outpost of their
;~              own (Ascalon Foothills, Majesty's Rest...) resolve to an outpost
;~              a few zones away, which is what makes caravanning necessary.
Func GW_FindStartOutpost($iMapId)
	If $g_bSimulationMode Then Return $iMapId + 1000

	Local $iOutpost = Map_FindNearestUnlockedOutpost($iMapId)
	If @error Or $iOutpost = 0 Then Return SetError(1, 0, 0)
	Return $iOutpost
EndFunc   ;==>GW_FindStartOutpost

;~ Description: Can we walk from where we are to $iMapId without passing through
;~              an outpost? True means the party can carry straight on instead of
;~              travelling, which is the whole point of caravanning.
Func GW_CanWalkTo($iMapId)
	If $g_bSimulationMode Then Return (Mod($iMapId, 2) = 0)
	If $iMapId <= 0 Or $iMapId = Map_GetMapID() Then Return False

	Local $aPath = Map_GetPathWithPortalCoords(Map_GetMapID(), $iMapId)
	If Not IsArray($aPath) Or UBound($aPath) < 2 Then Return False
	If UBound($aPath) - 1 > $MAX_PORTAL_HOPS Then Return False

	; An outpost on the way means travelling there is quicker and safer.
	For $i = 1 To UBound($aPath) - 1
		If Map_IsOutpost($aPath[$i][0]) Then Return False
	Next

	Return True
EndFunc   ;==>GW_CanWalkTo

;~ Description: Starts map travel. Arrival is polled, never waited for.
Func GW_BeginTravel($iOutpostId)
	If $g_bSimulationMode Then Return True

	Map_RndTravel($iOutpostId, False, True, 0)
	Return True
EndFunc   ;==>GW_BeginTravel
#EndRegion Location

#Region Zone entry
;~ Description: Called once every time the character lands in a new explorable
;~              area, however it got there - travelled, walked through a portal
;~              or resigned back in.
;~
;~              Two things have to happen on entry: the UtilityAI skill bar
;~              cache has to be rebuilt for the build we are carrying, and the
;~              foe counters have to be re-read as the baseline for this zone.
Func GW_OnZoneEntered($iMapId)
	$g_iZoneBaselineMapId = $iMapId
	$g_iZoneBaselineFoes = 0
	$g_iZoneBaselineKills = 0

	If $g_bSimulationMode Then Return True

	; The counters are not populated the instant the map reports as loaded.
	Local $hTimer = TimerInit()
	Do
		$g_iZoneBaselineFoes = World_GetWorldInfo("FoesToKill")
		$g_iZoneBaselineKills = World_GetWorldInfo("FoesKilled")
		If $g_iZoneBaselineFoes > 0 Then ExitLoop
		State_Yield()
		Sleep(200)
	Until TimerDiff($hTimer) > 5000

	If Not Cache_SkillBar() Then
		VqLog_Warn("The skill bar cache could not be built for this zone.")
		Return False
	EndIf

	VqLog_Info("Zone ready: " & GW_GetMapName($iMapId) & ", " & $g_iZoneBaselineFoes & " foes to kill.")
	Return True
EndFunc   ;==>GW_OnZoneEntered
#EndRegion Zone entry

#Region Vanquish status
;~ Description: Has this character already vanquished this map? Read from the
;~              account's vanquished-areas bit field, one bit per map id.
Func GW_IsMapVanquished($iMapId, $sMapName = "")
	If $g_bSimulationMode Then Return GWSim_IsMapVanquished($sMapName)
	If $iMapId <= 0 Then Return SetError(1, 0, False)

	Local $pArray = World_GetWorldInfo("VanquishedAreasArray")
	Local $iArraySize = World_GetWorldInfo("VanquishedAreasArraySize")
	If $pArray = 0 Or $iArraySize <= 0 Then Return SetError(1, 0, False)

	Local $iWord = Floor($iMapId / 32)
	If $iWord >= $iArraySize Then Return SetError(1, 0, False)

	Local $iBits = Memory_Read($pArray + ($iWord * 4), "dword")
	Return BitAND($iBits, BitShift(1, -Mod($iMapId, 32))) <> 0
EndFunc   ;==>GW_IsMapVanquished

;~ Description: Marks the start of an attempt so per-attempt bookkeeping resets.
Func GW_BeginZoneAttempt($iMapId, $sMapName = "")
	If $g_bSimulationMode Then
		GWSim_BeginZone($sMapName)
		Return True
	EndIf

	If $g_iZoneBaselineMapId <> $iMapId Then GW_OnZoneEntered($iMapId)
	Return True
EndFunc   ;==>GW_BeginZoneAttempt

;~ Description: Is the zone the character is standing in vanquished right now?
Func GW_IsCurrentZoneVanquished()
	If $g_bSimulationMode Then Return (GWSim_GetFoesRemaining() <= 0)

	If Not Map_GetInstanceInfo("IsExplorable") Then Return False
	If $REQUIRE_HARD_MODE And Not GW_IsHardMode() Then Return False
	If World_GetWorldInfo("FoesToKill") > 0 Then Return False

	; Nothing left to kill only means "vanquished" if we killed something.
	Return World_GetWorldInfo("FoesKilled") > $g_iZoneBaselineKills
EndFunc   ;==>GW_IsCurrentZoneVanquished

;~ Description: Foes left in the current zone, or -1 when it cannot be read.
Func GW_GetFoesRemaining()
	If $g_bSimulationMode Then Return GWSim_GetFoesRemaining()
	If Not Map_GetInstanceInfo("IsExplorable") Then Return -1
	Return World_GetWorldInfo("FoesToKill")
EndFunc   ;==>GW_GetFoesRemaining

;~ Description: True when the instance we just walked into was already empty, so
;~              the zone can be ticked off without walking its route.
Func GW_IsZoneAlreadyClear()
	If $g_bSimulationMode Then Return False
	If Not Map_GetInstanceInfo("IsExplorable") Then Return False
	Return World_GetWorldInfo("FoesToKill") = 0
EndFunc   ;==>GW_IsZoneAlreadyClear
#EndRegion Vanquish status

#Region Party
Func GW_IsHardMode()
	If $g_bSimulationMode Then Return True
	Return Party_GetPartyContextInfo("IsHardMode")
EndFunc   ;==>GW_IsHardMode

;~ Description: Vanquishing only counts in hard mode, so it is set in the
;~              outpost before the party is formed.
Func GW_SetHardMode()
	If Not $REQUIRE_HARD_MODE Then Return True
	If GW_IsHardMode() Then Return True

	If $g_bSimulationMode Then
		VqLog_Info("Hard mode would now be enabled.")
		Return True
	EndIf

	Ui_SetDifficulty(True)
	Sleep(500)
	Return GW_IsHardMode()
EndFunc   ;==>GW_SetHardMode

;~ Description: Fills the party from Vanquisher.ini for an area of this size.
;~              Returns True when the party is ready (including "it already
;~              was"), so the caller can simply retry until it is.
Func GW_FormParty($iPartySize)
	Local $aTeam = PartyConfig_GetTeam($iPartySize)
	If UBound($aTeam) = 0 Then
		VqLog_Warn("No " & $iPartySize & " man team is configured in " & $PARTY_INI_FILE & " - going in alone.")
		Return True
	EndIf

	If $g_bSimulationMode Then
		VqLog_Info("Party for a " & $iPartySize & " man area: " & PartyConfig_Describe($iPartySize) & ".")
		Return True
	EndIf

	If Not Map_GetInstanceInfo("IsOutpost") Then Return False

	; Only the size is compared: kicking and re-inviting a party that is already
	; full would cost several seconds in every outpost to change nothing.
	If GW_GetPartyMemberCount() = UBound($aTeam) + 1 Then Return True

	VqLog_Status("Forming the party: " & PartyConfig_Describe($iPartySize) & ".")
	Ui_LeaveGroup()
	GW_Wait(500)

	For $i = 0 To UBound($aTeam) - 1
		If $aTeam[$i][$ePARTY_SLOT_KIND] = $ePARTY_HERO Then
			GW_AddHeroByName($aTeam[$i][$ePARTY_SLOT_VALUE])
		Else
			GW_AddHenchmanByPlayerNumber(Number($aTeam[$i][$ePARTY_SLOT_VALUE]))
		EndIf
		GW_Wait(400)
	Next

	Return GW_GetPartyMemberCount() > 1
EndFunc   ;==>GW_FormParty

Func GW_GetPartyMemberCount()
	If $g_bSimulationMode Then Return 8
	Return Party_GetPartyContextInfo("TotalPartySize")
EndFunc   ;==>GW_GetPartyMemberCount

;~ Description: Invites a hero by the name used in the ini.
Func GW_AddHeroByName($sName)
	Local $iHeroId = 0
	For $i = 1 To $GC_AM2_HERO_DATA[0][0]
		If StringCompare($GC_AM2_HERO_DATA[$i][1], $sName, 0) = 0 Then
			$iHeroId = $GC_AM2_HERO_DATA[$i][0]
			ExitLoop
		EndIf
	Next

	If $iHeroId <= 0 Then
		VqLog_Warn("Unknown hero in the party setup: " & $sName & ".")
		Return False
	EndIf

	Ui_AddHero($iHeroId)
	Return True
EndFunc   ;==>GW_AddHeroByName

;~ Description: Invites the henchman standing in this outpost whose player
;~              number matches the ini entry.
Func GW_AddHenchmanByPlayerNumber($iPlayerNumber)
	If $iPlayerNumber <= 0 Then Return False

	$g_iWantedPlayerNumber = $iPlayerNumber
	Local $iAgentId = GetAgents(-2, 5000, $GC_I_AGENT_TYPE_LIVING, 1, "GW_FilterWantedPlayerNumber")
	If $iAgentId = 0 Then
		VqLog_Warn("Henchman " & $iPlayerNumber & " is not in this outpost.")
		Return False
	EndIf

	Ui_AddNPC($iAgentId)
	Return True
EndFunc   ;==>GW_AddHenchmanByPlayerNumber

Func GW_FilterWantedPlayerNumber($aAgentPtr)
	Return Agent_GetAgentInfo($aAgentPtr, "PlayerNumber") = $g_iWantedPlayerNumber
EndFunc   ;==>GW_FilterWantedPlayerNumber
#EndRegion Party

#Region Recovery
Func GW_IsPartyDead()
	If $g_bSimulationMode Then Return False
	Return Party_GetPartyContextInfo("IsDefeated")
EndFunc   ;==>GW_IsPartyDead

Func GW_IsPlayerDead()
	If $g_bSimulationMode Then Return False
	Return Agent_GetAgentInfo(-2, "IsDead")
EndFunc   ;==>GW_IsPlayerDead

;~ Description: Where the character is standing, as [x, y].
Func GW_GetPosition()
	Local $aPosition[2] = [0, 0]
	If $g_bSimulationMode Then Return $aPosition

	$aPosition[0] = Agent_GetAgentInfo(-2, "X")
	$aPosition[1] = Agent_GetAgentInfo(-2, "Y")
	Return $aPosition
EndFunc   ;==>GW_GetPosition

Func GW_Resign()
	If $g_bSimulationMode Then
		VqLog_Info("Resigning (simulated).")
		Return True
	EndIf

	Chat_SendChat("resign", "/")
	Return True
EndFunc   ;==>GW_Resign

;~ Description: Gets the party back to an outpost after a failed attempt.
;~              Returns quickly; the controller polls GW_IsInOutpost().
Func GW_ReturnToOutpost()
	If $g_bSimulationMode Then
		$g_bSimInOutpost = True
		$g_hSimZoneTimer = 0
		Return True
	EndIf

	If Map_GetInstanceInfo("IsOutpost") Then Return True

	GW_Resign()
	GW_Wait(3000)
	Map_ReturnToOutpost(False)
	Return True
EndFunc   ;==>GW_ReturnToOutpost

;~ Description: Sleep that keeps the window alive. Used by the few adapter calls
;~              that genuinely have to wait for the client.
Func GW_Wait($iMilliseconds)
	Local $hTimer = TimerInit()
	While TimerDiff($hTimer) < $iMilliseconds
		State_Yield()
		Sleep(50)
	WEnd
EndFunc   ;==>GW_Wait
#EndRegion Recovery

#Region Simulation helpers
;~ These exist so the framework can be run, watched and tested without the game.
;~ They are only ever reached while $g_bSimulationMode is True.

;~ Description: Deterministic "already vanquished?" answer, so repeated runs in
;~              simulation behave consistently.
Func GWSim_IsMapVanquished($sMapName)
	Local $iHash = 0
	For $i = 1 To StringLen($sMapName)
		$iHash = Mod($iHash * 31 + Asc(StringMid($sMapName, $i, 1)), 100)
	Next
	Return ($iHash < $SIM_VANQUISHED_PERCENT)
EndFunc   ;==>GWSim_IsMapVanquished

Func GWSim_BeginZone($sMapName)
	$g_hSimZoneTimer = TimerInit()
	$g_iSimZoneFoes = $SIM_ZONE_FOES
	$g_bSimZoneDoomed = (Random(1, 100, 1) <= $SIM_ZONE_FAIL_PERCENT)

	If $g_bSimZoneDoomed Then
		VqLog_Info("Simulation: this attempt at " & $sMapName & " will get stuck, so the timeout/retry path runs.")
	EndIf
EndFunc   ;==>GWSim_BeginZone

;~ Description: Simulated foe count, falling off over $SIM_ZONE_MS. A "doomed"
;~              attempt stalls with foes left so the zone timeout fires.
Func GWSim_GetFoesRemaining()
	If $g_hSimZoneTimer = 0 Then Return -1

	Local $fProgress = TimerDiff($g_hSimZoneTimer) / $SIM_ZONE_MS
	If $g_bSimZoneDoomed And $fProgress > 0.75 Then $fProgress = 0.75
	If $fProgress > 1 Then $fProgress = 1

	$g_iSimZoneFoes = Int($SIM_ZONE_FOES * (1 - $fProgress))
	Return $g_iSimZoneFoes
EndFunc   ;==>GWSim_GetFoesRemaining

;~ Description: Called by the simulated pathfinder when it "arrives" somewhere.
Func GW_SimSetLocation($iMapId, $bInOutpost)
	$g_iSimMapId = $iMapId
	$g_bSimInOutpost = $bInOutpost
EndFunc   ;==>GW_SimSetLocation
#EndRegion Simulation helpers
