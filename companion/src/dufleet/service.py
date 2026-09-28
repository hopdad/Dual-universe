"""`dufleet run`: the companion for one bot, until it is stopped.

It signs in to the hub as the bot's device user and starts the transport. It runs the
command pump, and the frame router takes the transport's lines. A realtime subscription on
the bot's commands wakes the pump, whose poll covers a subscription that drops.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging

from dufleet.config import Config
from dufleet.hub import Hub
from dufleet.pump import CommandPump
from dufleet.router import FrameRouter
from dufleet.transport import Transport, make_transport

log = logging.getLogger(__name__)


async def serve(cfg: Config, *, hub: Hub | None = None, transport: Transport | None = None,
                stop: asyncio.Event | None = None) -> CommandPump:
    """Runs until `stop` is set (or forever), then closes the transport. Returns the pump, for its stats."""
    if hub is None:
        from dufleet.supabase_hub import SupabaseHub

        hub = await SupabaseHub.connect(cfg.hub.url, cfg.hub.publishable_key, cfg.hub.email, cfg.hub.password())
    transport = transport or make_transport(cfg.transport)
    bot = str(cfg.bot.id)
    pump = CommandPump(hub, bot, transport.send, transport=transport.letter, lease_s=cfg.pump.lease_s,
                       poll_s=cfg.pump.poll_s, idle_s=cfg.pump.idle_s, lost_s=cfg.pump.lost_s)
    router = FrameRouter(hub, bot, pump)
    await transport.start(router.feed)
    task = asyncio.create_task(pump.run())
    try:
        watch = getattr(hub, "watch_commands", None)
        if watch is not None:
            try:
                await watch(bot, pump.wake)
            except Exception:
                log.warning("no realtime subscription; polling every %s s", cfg.pump.poll_s, exc_info=True)
        log.info("serving bot %s over transport %s", bot, transport.letter)
        await (stop.wait() if stop is not None else task)
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        await transport.close()
    return pump
