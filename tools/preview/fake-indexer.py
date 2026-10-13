# Stands in for the search service's indexing progress in the preview (session.sh, INDEXING="DELAY
# DURATION"): owns local.embedsearch, waits DELAY seconds, then its Progress goes from 0 to 1 over
# DURATION seconds and back to -1, as the real service reports it while it indexes.
import asyncio
import sys
import time

from dbus_fast.aio import MessageBus
from dbus_fast.constants import PropertyAccess
from dbus_fast.service import ServiceInterface, dbus_property


class Indexer(ServiceInterface):
    def __init__(self):
        super().__init__("local.embedsearch.Indexer")
        self.progress = -1.0

    @dbus_property(access=PropertyAccess.READ)
    def Progress(self) -> "d":
        return self.progress

    def set(self, value):
        self.progress = value
        self.emit_properties_changed({"Progress": value})


async def main(delay, duration):
    bus = await MessageBus().connect()
    indexer = Indexer()
    bus.export("/indexer", indexer)
    await bus.request_name("local.embedsearch")
    await asyncio.sleep(delay)
    t0 = time.monotonic()
    while (t := time.monotonic() - t0) < duration:
        indexer.set(t / duration)
        await asyncio.sleep(0.25)
    indexer.set(1.0)
    await asyncio.sleep(0.25)
    indexer.set(-1.0)
    await bus.wait_for_disconnect()


asyncio.run(main(float(sys.argv[1]), float(sys.argv[2])))
