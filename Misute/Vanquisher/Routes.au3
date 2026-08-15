#include-once
#include "Routes/Prophecies.au3"
#include "Routes/Factions.au3"
#include "Routes/Nightfall.au3"
#include "Routes/EyeOfTheNorth.au3"

#cs ----------------------------------------------------------------------------

    Routes.au3

    One Route_<Name>() function per zone, grouped by campaign under Routes/.
    A route is only "where to walk next" - an [n][2] array of x/y. The
    pathfinder finds the way between waypoints and fights everything inside its
    aggro range, so a loop that passes every spawn is enough; the controller
    reruns the route if the zone is not clear when it ends.

    Where the reference had several arrays per zone (forward, reverse, extra
    loops) they are concatenated in the order it ran them, so nothing is lost.

    Coordinates come from mrdomrocks' Guild Wars Vanquish Bot (MIT):
    https://github.com/mrdomrocks/Guild-Wars-Vanquish-Bot

#ce ----------------------------------------------------------------------------

;~ Description: The waypoints registered under a route name, or an error when
;~              nothing is registered under it.
Func Routes_Get($sRouteName)
	If $sRouteName = "" Then Return SetError(1, 0, 0)

	Local $aRoute = Call("Route_" & $sRouteName)
	If @error = 0xDEAD And @extended = 0xBEEF Then Return SetError(1, 0, 0)
	If Not IsArray($aRoute) Then Return SetError(2, 0, 0)

	Return $aRoute
EndFunc   ;==>Routes_Get
