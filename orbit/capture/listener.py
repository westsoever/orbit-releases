import queue
import time
import logging
import objc
from AppKit import NSWorkspace, NSWorkspaceDidActivateApplicationNotification
from Foundation import NSNotificationCenter, NSObject
from orbit.capture.exclusions import EXCLUDED_BUNDLES

logger = logging.getLogger(__name__)

class _Observer(NSObject):
    def initWithQueue_interval_(self, q, min_interval_s):
        self = objc.super(_Observer, self).init()
        if self is None:
            return None
        self._q = q
        self._min_interval = min_interval_s
        self._last_seen = {}  # bundle -> float (time.monotonic)
        return self

    def appActivated_(self, notification):
        info = notification.userInfo()
        app = info.get("NSWorkspaceApplicationKey")
        if app is None:
            return
        bundle = app.bundleIdentifier()
        if bundle in EXCLUDED_BUNDLES:
            return
        now = time.monotonic()
        if now - self._last_seen.get(bundle, 0) < self._min_interval:
            return
        self._last_seen[bundle] = now
        self._q.put({
            "bundle_id": bundle,
            "app_name": app.localizedName(),
            "pid": int(app.processIdentifier()),
            "ts": time.time(),
        })

class AppFocusListener:
    def __init__(self, q: queue.Queue | None = None, min_interval_s: float = 1.5):
        self._q: queue.Queue = q if q is not None else queue.Queue()
        self._observer = _Observer.alloc().initWithQueue_interval_(self._q, min_interval_s)
        ws = NSWorkspace.sharedWorkspace()
        nc = ws.notificationCenter()
        nc.addObserver_selector_name_object_(
            self._observer,
            "appActivated:",
            NSWorkspaceDidActivateApplicationNotification,
            None,
        )

    @property
    def queue(self) -> queue.Queue:
        return self._q

    def stop(self):
        ws = NSWorkspace.sharedWorkspace()
        nc = ws.notificationCenter()
        nc.removeObserver_(self._observer)
