"""FSEvents listener — Tier 3 workspace path capture (paths only, no contents)."""

from __future__ import annotations

import logging
import os
import queue
from datetime import datetime, timezone
from pathlib import Path

import FSEvents
from Cocoa import CFRunLoopGetCurrent, kCFRunLoopDefaultMode
from Foundation import NSArray

logger = logging.getLogger(__name__)

STREAM_LATENCY_S = 1.0

_FLAG_TO_TYPE = (
    (FSEvents.kFSEventStreamEventFlagItemCreated, "created"),
    (FSEvents.kFSEventStreamEventFlagItemRemoved, "removed"),
    (FSEvents.kFSEventStreamEventFlagItemModified, "modified"),
    (FSEvents.kFSEventStreamEventFlagItemRenamed, "renamed"),
)


def expand_watch_roots(roots: list[str]) -> list[str]:
    expanded: list[str] = []
    for root in roots:
        path = Path(os.path.expanduser(root)).resolve()
        if path.is_dir():
            expanded.append(str(path))
        else:
            logger.warning("FSEvents watch root missing or not a directory: %s", root)
    return expanded


def event_type_from_flags(flags: int) -> str:
    for flag, name in _FLAG_TO_TYPE:
        if flags & flag:
            return name
    return "unknown"


def coalesce_batch(paths: list, flags: list) -> dict[str, int]:
    merged: dict[str, int] = {}
    for path, mask in zip(paths, flags):
        merged[str(path)] = int(mask)
    return merged


class FSEventsListener:
    """Schedule FSEventStream on the current CFRunLoop (daemon main loop)."""

    def __init__(
        self,
        q: queue.Queue,
        watch_roots: list[str],
        latency_s: float = STREAM_LATENCY_S,
    ):
        self._q = q
        self._stream = None
        self._callback = None
        paths = expand_watch_roots(watch_roots)
        if not paths:
            logger.warning("FSEvents: no valid watch roots; listener inactive")
            return

        def callback(
            stream_ref,
            client_info,
            num_events,
            event_paths,
            event_flags,
            event_ids,
        ):
            del stream_ref, client_info, event_ids
            merged = coalesce_batch(
                list(event_paths)[:num_events],
                list(event_flags)[:num_events],
            )
            ts = datetime.now(timezone.utc).isoformat()
            for path, mask in merged.items():
                self._q.put(
                    {
                        "timestamp": ts,
                        "path": path,
                        "event_type": event_type_from_flags(mask),
                    }
                )

        self._callback = callback
        path_array = NSArray.arrayWithArray_(paths)
        self._stream = FSEvents.FSEventStreamCreate(
            None,
            callback,
            None,
            path_array,
            FSEvents.kFSEventStreamEventIdSinceNow,
            max(float(latency_s), STREAM_LATENCY_S),
            FSEvents.kFSEventStreamCreateFlagFileEvents
            | FSEvents.kFSEventStreamCreateFlagUseCFTypes,
        )
        if not self._stream:
            raise RuntimeError("FSEventStreamCreate failed")

        FSEvents.FSEventStreamScheduleWithRunLoop(
            self._stream,
            CFRunLoopGetCurrent(),
            kCFRunLoopDefaultMode,
        )
        if not FSEvents.FSEventStreamStart(self._stream):
            raise RuntimeError("FSEventStreamStart failed")

        logger.info(
            "FSEvents watching %d root(s): %s",
            len(paths),
            ", ".join(paths),
        )

    def stop(self) -> None:
        if self._stream is None:
            return
        FSEvents.FSEventStreamStop(self._stream)
        FSEvents.FSEventStreamInvalidate(self._stream)
        FSEvents.FSEventStreamRelease(self._stream)
        self._stream = None
