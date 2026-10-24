"""In-process publish/subscribe hub behind the SSE streams (score updates and chat).

Publishers are usually sync request handlers running in FastAPI's thread pool (for example the event
engine after an append), while subscribers are async SSE generators on the event loop. ``publish`` is
therefore thread-safe and hands each item to the subscriber's loop with ``call_soon_threadsafe``.

Channels used today: ``match:{match_id}`` (event ``score``) and ``chat:{chat_room_id}`` (``chat``, ``reset``).
"""
import asyncio
import threading
from typing import Optional


class Subscription:
    def __init__(self, channel: str, loop: asyncio.AbstractEventLoop, queue_size: int):
        self.channel = channel
        self.loop = loop
        self.queue: asyncio.Queue = asyncio.Queue(maxsize=queue_size)

    def offer(self, event: str, data: dict) -> None:
        try:
            self.loop.call_soon_threadsafe(self._put, (event, data))
        except RuntimeError:  # the subscriber's loop is already closed
            pass

    def _put(self, item) -> None:
        if self.queue.full():
            self.queue.get_nowait()  # drop the oldest; score snapshots are cumulative, so the newest wins
        self.queue.put_nowait(item)

    async def next(self, timeout: float) -> Optional[tuple]:
        """Next (event, data) pair, or None when nothing arrived within ``timeout`` seconds."""
        try:
            return await asyncio.wait_for(self.queue.get(), timeout)
        except asyncio.TimeoutError:
            return None


class LiveFeed:
    def __init__(self, queue_size: int = 64):
        self.queue_size = queue_size
        self._lock = threading.Lock()
        self._subs: dict = {}

    def subscribe(self, channel: str) -> Subscription:
        """Must be called from inside a running event loop (an async route)."""
        sub = Subscription(channel, asyncio.get_running_loop(), self.queue_size)
        with self._lock:
            self._subs.setdefault(channel, set()).add(sub)
        return sub

    def unsubscribe(self, sub: Subscription) -> None:
        with self._lock:
            subs = self._subs.get(sub.channel)
            if subs:
                subs.discard(sub)
                if not subs:
                    del self._subs[sub.channel]

    def has_subscribers(self, channel: str) -> bool:
        with self._lock:
            return bool(self._subs.get(channel))

    def channels(self, prefix: str = "") -> list:
        with self._lock:
            return [c for c in self._subs if c.startswith(prefix)]

    def subscriber_count(self) -> int:
        """Open stream connections; Group 3 can export this as nascon_active_ws_connections."""
        with self._lock:
            return sum(len(s) for s in self._subs.values())

    def publish(self, channel: str, event: str, data: dict) -> None:
        with self._lock:
            subs = list(self._subs.get(channel, ()))
        for sub in subs:
            sub.offer(event, data)
