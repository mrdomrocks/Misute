#cs ----------------------------------------------------------------------------

    Simulation.au3 - run this to try the vanquisher without Guild Wars.

    The adapters answer with fake but realistic data: zones take a while, some
    are already vanquished, some attempts fail and time out, and the caravan
    walks through zones on its way. Everything else - the GUI, the queue, the
    retries, the party setup, the logging - is the real thing.

    Useful for demonstrating the workflow, and for checking a change to the
    controller without a client attached.

#ce ----------------------------------------------------------------------------

#include "App.au3"

App_Run(True)
