"""The browser worker: takes `submitting` registrations from SpacetimeDB, runs them, reports back.

It runs inside the API process by default, and can also run alone:  python -m agent.services.worker
Several workers are safe: claim_registration lets only one of them take a registration.
"""
import asyncio
import logging

from .. import store
from . import runner

log = logging.getLogger("parkour.worker")
POLL_SECONDS = 1.0
_wake: asyncio.Event | None = None
_loop: asyncio.AbstractEventLoop | None = None


def wake():
    """Check for new work now instead of at the next poll (safe from any thread)."""
    if _loop and _wake:
        _loop.call_soon_threadsafe(_wake.set)


async def loop():
    global _wake, _loop
    _wake, _loop = asyncio.Event(), asyncio.get_running_loop()
    released = False
    while True:
        try:
            s = store.get_store()
            if not released:
                s.release_stuck()  # anything a crashed worker was holding goes back in the queue
                released = True
            for reg in s.registrations_with_status("submitting"):
                if reg["_run_state"] == "" and s.claim(reg["registration_id"]):
                    runner.start(reg["registration_id"])
        except Exception as e:
            log.warning("worker poll failed: %s", type(e).__name__)
        try:
            await asyncio.wait_for(_wake.wait(), POLL_SECONDS)
        except asyncio.TimeoutError:
            pass
        _wake.clear()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(loop())
