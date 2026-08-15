#RequireAdmin

#cs ----------------------------------------------------------------------------

    Vanquisher.au3 - run this to vanquish with a real Guild Wars client.

    The GwAu3 API and its pathfinder plugin are included here, and only here, so
    that Simulation.au3 can run exactly the same application without them.

    The paths below assume the usual GwAu3 layout, with this bot living in the
    API's Scripts folder:

        GwAu3/
        |- API/
        |  |- _GwAu3.au3
        |  '- Plugins/Pathfinder/_Pathfinder.au3
        '- Scripts/Misute/Vanquisher/Vanquisher.au3   <- this file

#ce ----------------------------------------------------------------------------

#include "../../../API/_GwAu3.au3"
#include "../../../API/Plugins/Pathfinder/_Pathfinder.au3"

#include "App.au3"

App_Run(False)
