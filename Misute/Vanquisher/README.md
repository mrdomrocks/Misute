# Misute Vanquisher

An automated Guild Wars 1 vanquisher for the [GwAu3](https://github.com/GwAu3-Projects/GwAu3)
API: a GUI, a controller that works through a queue of zones with retries and a
two hour per-attempt ceiling, and adapters that drive the client and the GwAu3
pathfinder plugin.

Two entry points run the same application:

```text
AutoIt3.exe Vanquisher.au3    attaches to a running Guild Wars client
AutoIt3.exe Simulation.au3    the whole workflow with no client at all
```

`Simulation.au3` needs nothing installed and is the quickest way to see the
workflow - travel, party setup, walking in, vanquishing, confirming, retrying,
timing out and stopping - all in the GUI.

---

## Layout

```text
Misute/Vanquisher/
├── Vanquisher.au3      entry point: includes the GwAu3 API, runs for real
├── Simulation.au3      entry point: same application, fake adapters
├── App.au3             startup and the application loop
├── GUI.au3             window, events, refresh, log console
├── BotController.au3   state machine, work queue, retries, timeout, caravanning
├── Maps.au3            the zone database and per-zone status
├── Routes.au3          the waypoints for each zone
├── GuildWars.au3       game adapter: client, map, party, vanquish state
├── Pathfinder.au3      movement adapter: travel, portal hops, routes
├── PartyConfig.au3     hero/henchman setup, read from Vanquisher.ini
├── BotState.au3        shared state: the contract between GUI and controller
├── Config.au3          every tunable value
├── Log.au3             central logging
└── Vanquisher.ini      the teams used for 4, 6 and 8 man areas
```

Dependencies only ever point downwards:

```text
        GUI.au3
           │  StartBot() / RequestStop(), reads BotState, Maps and PartyConfig
           ▼
     BotController.au3
           │
     ┌─────┴──────┐
     ▼            ▼
 Maps.au3   Pathfinder.au3 ──► GuildWars.au3 ──► GwAu3 ──► Guild Wars client
                  │                  ▲
             Routes.au3         PartyConfig.au3

  BotState.au3 / Log.au3 / Config.au3 are used by everything and depend on
  nothing, so neither logging nor progress reporting couples the layers.
```

---

## The state machine

```text
  IDLE ──Start──► INITIALISING ──► CHECKING ──► NEXT_MAP ──► TRAVELLING
                                       │            ▲            │
                                  (all done)        │            ▼
                                       │            │        PREPARING
                                       ▼            │            │
                                   FINISHED         │            ▼
                                                    │         ENTERING
                                                    │            │
                                        CONFIRMING ◄┴──── VANQUISHING
                                             │                   ▲
                                             └───────────────────┘

  any state ──failure/timeout──► RECOVERING ──► NEXT_MAP
  any state ──stop requested──► STOPPING ──► IDLE
  fatal problem ─────────────► ERROR (GUI stays open, Start works again)
```

| State | What happens |
|---|---|
| `INITIALISING` | attaches to the client, then loads the pathfinder plugin with the ranges from `Config.au3` |
| `CHECKING` | reads the vanquished bit for every zone, a couple per tick, then builds the queue |
| `NEXT_MAP` | takes the front of the queue, resolves the nearest unlocked outpost and the area's party size, **starts a fresh two hour timer** |
| `TRAVELLING` | map travel to that outpost - skipped when the party is already in the field and can walk there |
| `PREPARING` | sets hard mode and forms the team for the area's size from `Vanquisher.ini` |
| `ENTERING` | walks portal to portal until it reaches the zone, claiming any zone on the list it crosses |
| `VANQUISHING` | walks the route; the pathfinder fights everything inside its aggro range |
| `CONFIRMING` | re-checks the vanquish before ticking the zone off |
| `RECOVERING` | aborts the pathfinder, resigns back to an outpost, carries on |
| `STOPPING` | safe halt: pathfinder stopped, zone handed back to the queue, bot idle |

### Why the controller is a tick machine

`App.au3` owns the loop:

```autoit
While True
    Bot_Tick()      ; one small slice of bot work, always returns quickly
    GUI_Update()    ; repaint anything that changed
    Sleep($TICK_SLEEP_MS)
WEnd
```

so the window keeps repainting while the bot works, a stop request is noticed
within milliseconds, and the zone timer is checked continuously rather than at
the end of some long operation. The one call that genuinely blocks -
`Pathfinder_MoveTo()`, which returns when it arrives - is given a per-iteration
callback that repaints the window, and is only ever asked for one waypoint or
one portal at a time.

---

## Getting to a zone, and caravanning

Half the vanquishable zones have no outpost of their own, so "travel, walk out,
start" is not enough. Rather than hand-writing a route out of every outpost, the
bot asks the API two questions:

```autoit
Map_FindNearestUnlockedOutpost($iZoneMapId)          ; where do we start from?
Map_GetPathWithPortalCoords($iFromMapId, $iToMapId)  ; which maps, which portals?
```

The second returns one row per map crossed, each with the coordinates of the
exit portal out of it - the exit coordinates that ship with GwAu3. One call
therefore covers both cases:

* **one hop** - the zone is next to the outpost, so the bot walks out and starts;
* **many hops** - the zone is several zones away, so the party **caravans**: it
  walks to the portal, crosses, and repeats, fighting its way across each zone.

A hop only counts when the map id actually changes, which is what stops the bot
pacing back and forth over a portal it never crosses.

Two things fall out of that for free:

* **Zones claimed on the way.** If the party crosses a zone that is on the list
  and still needs doing, `Bot_ClaimCurrentZone()` makes it the active zone and
  the original target goes back in the queue. It is on the far side of here
  anyway, so nothing is lost.
* **No pointless travelling.** After a vanquish, if the next zone can be reached
  on foot without passing through an outpost (`GW_CanWalkTo()`), the party
  simply carries on instead of resigning and travelling.

---

## Zones and routes

One zone is one `Maps_Register()` line in `Maps_Load()` (`Maps.au3`):

```autoit
Maps_Register("Regent Valley", 101, "Ascalon", "RegentValley")
;             zone name        id   region     route name in Routes.au3
```

Outpost, party size, status, attempts and last result are filled in while the
bot runs, so a zone with no outpost needs no special handling.

A route is a plain array of waypoints in `Routes.au3`:

```autoit
Func Route_RegentValley()
    Local $aRoute[106][2] = [ _
            [21699, 3672], [20858, 3211], ... _
    ]
    Return $aRoute
EndFunc
```

Routes are deliberately dumb - only "where to walk next". The pathfinder finds
the way between two waypoints and fights everything inside its aggro range on
the way, so a loop that passes every spawn is enough. If the zone is not clear
when the route ends, the controller runs it again (up to `$MAX_ROUTE_LOOPS`).

The shipped coordinates come from
[mrdomrocks' Guild Wars Vanquish Bot](https://github.com/mrdomrocks/Guild-Wars-Vanquish-Bot)
(MIT).

---

## Party setup

Areas allow 4, 6 or 8 characters, so one team will not do. `Vanquisher.ini`
holds one section per size and the bot picks the right one when it arrives:

```ini
[Team6]
Hero1=Norgu
Hero2=Gwen
Hero3=Olias
Hero4=Master of Whispers
Hero5=Xandra
Henchman1=2001
```

Heroes are named as the game names them; henchmen use their player number,
because henchman names cannot be read from the client. Heroes are invited
first, then henchmen, and anything past the area's limit is ignored. The Party
tab in the GUI shows what is configured and reloads the file on demand.

Hard mode is set in the same step - a vanquish does not count without it.

---

## Work queue, retries and the two hour rule

* **Queue** - a plain array of zone indices, worked from the front. A zone
  leaves the queue when it is confirmed vanquished or has finally failed.
* **Retries** - `MAX_RETRIES = 3`. Attempts 1 and 2 send the zone to the **back**
  of the queue (so one bad zone does not block the rest); attempt 3 marks it
  failed and moves on.
* **Timeout** - a fresh timer starts on every attempt and is checked at the top
  of every tick of every state inside that attempt, so no matter where the bot
  gets stuck it cannot exceed `$ZONE_TIMEOUT_MS` (two hours). Shorter per-step
  ceilings (travel, party, walking in, confirming, recovering) catch obvious
  hangs much sooner.
* **Every failure path** - pathfinder failure, dead party, timeout, unexpected
  state - funnels into `Bot_AttemptFailed()`, the single place that decides
  "retry" or "give up". That is what makes an infinite loop impossible.

`RequestStop()` only sets a flag. The next tick moves to `STOPPING`, which stops
the pathfinder, hands the in-progress zone back to the queue and returns the bot
to idle with the window still open.

---

## Vanquish detection

Two different questions, two different sources:

* **"Has this character already done this zone?"** - the account's
  vanquished-areas bit field, one bit per map id, read once per zone during
  `CHECKING`.
* **"Is the zone we are standing in clear?"** - `FoesToKill` reaching zero
  *and* `FoesKilled` having risen since we entered. Without the second half,
  walking into an instance somebody else cleared would look like a fresh
  vanquish.

Every explorable area the bot lands in - travelled to, walked into or resigned
back into - goes through `GW_OnZoneEntered()`, which rebuilds the UtilityAI
skill bar cache (`Cache_SkillBar()`) and re-reads the foe counters as the
baseline for that zone.

---

## Installation

The paths in `Vanquisher.au3` assume the usual GwAu3 layout:

```text
GwAu3/
├── API/
│   ├── _GwAu3.au3
│   └── Plugins/Pathfinder/_Pathfinder.au3    (and GWPathfinder.dll)
└── Scripts/Misute/Vanquisher/Vanquisher.au3
```

The pathfinder plugin downloads its own map data on first use. AutoIt 3.3.16.1
or newer, 32-bit, and administrator rights (reading the client's memory needs
them) are required.

Logs are written to `vanquish_log.txt` next to the script, reopened per line so
the file survives a crash, and mirrored into the GUI console.
