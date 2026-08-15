#include-once

#cs ----------------------------------------------------------------------------

    Config.au3

    Every tunable value used by the vanquisher lives in this file. Nothing in
    here does any work - it only declares constants and the handful of globals
    that describe "how the bot should behave".

    Change behaviour here, not in the controller.

#ce ----------------------------------------------------------------------------

#Region Identity
Global Const $VQ_BOT_TITLE = "Misute Vanquisher"
Global Const $VQ_BOT_VERSION = "1.1.0"
#EndRegion Identity

#Region Mode
;~ Simulation mode lets the whole application run without Guild Wars: the game
;~ and pathfinder adapters answer with fake but realistic data, so the GUI, the
;~ work queue, the retry logic and the zone timeout can all be exercised.
;~
;~ It is chosen by the entry point, not edited here:
;~     Vanquisher.au3   real client (includes the GwAu3 API)
;~     Simulation.au3   no client needed
Global $g_bSimulationMode = True
#EndRegion Mode

#Region Retry and timeout
;~ How many attempts a single zone gets before it is marked as failed and the
;~ bot moves on. Attempt 1 + 2 retry, attempt 3 fails the map.
Global Const $MAX_RETRIES = 3

;~ The two hour per-attempt ceiling required by the workflow. A fresh timer is
;~ started for every attempt at a zone; see State_StartZoneTimer().
Global Const $ZONE_TIMEOUT_MS = 7200000      ; 2 hours

;~ Simulation shortens the ceiling so the timeout path can actually be observed.
Global Const $SIM_ZONE_TIMEOUT_MS = 60000    ; 1 minute

;~ The value the controller actually enforces; set by Config_ApplyMode().
Global $g_iZoneTimeoutMs = $ZONE_TIMEOUT_MS

;~ Shorter ceilings for the individual steps inside an attempt. These stop the
;~ bot sitting in one step for the full two hours when something is obviously
;~ wrong (for example a travel that never completes).
Global Const $TRAVEL_TIMEOUT_MS = 180000      ; 3 minutes to reach an outpost
Global Const $PREPARE_TIMEOUT_MS = 60000      ; 1 minute to form the party
Global Const $ENTER_ZONE_TIMEOUT_MS = 900000  ; 15 minutes of portal hopping
Global Const $CONFIRM_TIMEOUT_MS = 30000      ; 30 seconds to confirm a vanquish
Global Const $RECOVER_TIMEOUT_MS = 120000     ; 2 minutes to get back to safety

;~ If the pathfinder route finishes but the zone is not vanquished the route is
;~ run again. This caps how many times that happens per attempt.
Global Const $MAX_ROUTE_LOOPS = 3

;~ True  = a retried map goes to the back of the queue (other maps get a turn).
;~ False = a retried map is attempted again immediately.
Global Const $RETRY_AT_END_OF_QUEUE = True
#EndRegion Retry and timeout

#Region Pathfinder
;~ The GwAu3 pathfinder plugin. $DLL_PATH is the variable the plugin itself
;~ reads, so it is declared here and filled in by Pathfinder_Init().
Global $DLL_PATH = ""
Global Const $PATH_DLL_RELATIVE = "\..\..\..\API\Plugins\Pathfinder\GWPathfinder.dll"

;~ Ranges the pathfinder is initialised with. Aggro range is how far the bot
;~ will step off the path to engage; fight-range-out is how far it is allowed to
;~ be dragged from the anchor point before it disengages.
Global Const $PATH_AGGRO_RANGE = 1320
Global Const $PATH_FIGHT_RANGE_OUT = 3500

;~ Portal hops are walked with a tighter aggro range: the point is to cross the
;~ map line, not to clear the zone on the way.
Global Const $PATH_TRANSIT_AGGRO_RANGE = 700

;~ Path shape. Simplify range is the maximum gap between two non-critical
;~ waypoints, reached-distance is when a waypoint counts as visited.
Global Const $PATH_SIMPLIFY_RANGE = 1250
Global Const $PATH_WAYPOINT_REACHED = 250
Global Const $PATH_UPDATE_INTERVAL_MS = 1000
Global Const $PATH_OBSTACLE_UPDATE_MS = 1000

;~ Moving agents are fed to the pathfinder as obstacles so it walks around them.
Global Const $PATH_OBSTACLE_FUNC = "UAI_GetObstacles"

;~ A waypoint this close to the character is skipped rather than walked to.
Global Const $PATH_WAYPOINT_SKIP_RANGE = 200

;~ How many portal hops one zone transfer may take before it is given up on.
Global Const $MAX_PORTAL_HOPS = 24

;~ Death recovery. A full wipe is not the end of an attempt: the game brings
;~ the party back at a resurrection shrine (usually after ~15 seconds) and the
;~ route is resumed from the waypoint nearest the death spot. Only when the
;~ same job wipes this many times is the attempt failed.
Global Const $MAX_DEATHS_PER_JOB = 3
Global Const $RESPAWN_TIMEOUT_MS = 30000
#EndRegion Pathfinder

#Region Vanquishing
;~ Vanquishing only counts in hard mode, so the bot sets it before leaving.
Global Const $REQUIRE_HARD_MODE = True

;~ Caravanning: many zones have no outpost of their own. When this is on the bot
;~ walks in from the nearest unlocked outpost through as many zones as it takes,
;~ and vanquishes any zone on its list that it passes through on the way.
Global Const $CARAVAN_ENABLED = True
#EndRegion Vanquishing

#Region Party
;~ Hero/henchman setup per party size, kept in an ini next to the script so it
;~ survives updates and can be edited without touching any code.
Global Const $PARTY_INI_FILE = @ScriptDir & "\Vanquisher.ini"

;~ Party sizes the game uses for explorable areas.
Global Const $PARTY_SIZES[3] = [4, 6, 8]
#EndRegion Party

#Region Pacing
;~ Main loop sleep. Small enough for a responsive GUI, large enough that the
;~ script does not burn a core while idle.
Global Const $TICK_SLEEP_MS = 25

;~ How often the GUI redraws time based fields when nothing else has changed.
Global Const $GUI_REFRESH_MS = 250

;~ Floor on redraws. A change in bot state is shown this quickly, and never
;~ faster, so a chatty state does not turn into hundreds of repaints a second.
Global Const $GUI_MIN_REPAINT_MS = 100

;~ How many maps are queried per tick while checking vanquished status. Keeping
;~ this low means a long map list does not freeze the GUI.
Global Const $MAPS_CHECKED_PER_TICK = 2

;~ How often "still vanquishing" progress is written to the log.
Global $g_iProgressLogIntervalMs = 60000
#EndRegion Pacing

#Region Logging
Global Const $VQ_LOG_FILE = @ScriptDir & "\vanquish_log.txt"

;~ GwAu3_AddOns.au3 writes to $g_s_LogFile. Declaring it here means legacy log
;~ calls from the API end up in the same file instead of failing.
Global Const $g_s_LogFile = $VQ_LOG_FILE

;~ Number of log lines kept in memory so a GUI can be (re)attached and still
;~ show recent history.
Global Const $LOG_RING_SIZE = 400

;~ When the GUI console holds more lines than this it is re-rendered from the
;~ ring buffer, which keeps memory flat during unattended multi-day runs.
Global Const $GUI_LOG_MAX_LINES = 600
#EndRegion Logging

#Region Simulation timings
;~ Only used while $g_bSimulationMode.
Global Const $SIM_CONNECT_MS = 1200          ; time "connecting" to the client
Global Const $SIM_MAP_CHECK_MS = 120         ; time to read one map's status
Global Const $SIM_TRAVEL_MS = 5000           ; time to travel to an outpost
Global Const $SIM_PREPARE_MS = 2500          ; time to form the party
Global Const $SIM_PORTAL_MS = 4000           ; time to walk to one portal
Global Const $SIM_ZONE_MS = 25000            ; time to clear a zone
Global Const $SIM_ZONE_FOES = 180            ; foes at the start of a zone
Global Const $SIM_ZONE_FAIL_PERCENT = 20     ; chance a zone attempt gets stuck
Global Const $SIM_PATH_FAIL_PERCENT = 8      ; chance a pathfinder call fails
Global Const $SIM_VANQUISHED_PERCENT = 25    ; chance a map is already done
#EndRegion Simulation timings

#Region Runtime options
;~ Set from the command line (-character "Name" [-autostart]). $g_bAutoStart is
;~ the name GwAu3 uses for the same flag, and is deliberately shared with it.
Global $g_sTargetCharacter = ""
Global $g_bAutoStart = False

;~ True when the character combo should be filled from the API's scanner.
Global $g_bLoadLoggedChars = True
#EndRegion Runtime options

#Region Mode switch
;~ Description: Applies the mode chosen by the entry point. Call once, before
;~              anything reads the derived values.
Func Config_ApplyMode($bSimulation)
	$g_bSimulationMode = $bSimulation
	$g_iZoneTimeoutMs = ($bSimulation) ? $SIM_ZONE_TIMEOUT_MS : $ZONE_TIMEOUT_MS
	$g_iProgressLogIntervalMs = ($bSimulation) ? 4000 : 60000
EndFunc   ;==>Config_ApplyMode
#EndRegion Mode switch
