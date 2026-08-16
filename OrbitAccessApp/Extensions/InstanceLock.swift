import Darwin
import Foundation
import OSLog

/// Advisory single-instance lock on `~/.orbit/access-app.lock` (`OrbitPaths.accessAppLockURL`).
///
/// This is the *second* line of defence — `AppDelegate.enforceSingleInstance()` checks
/// `NSRunningApplication` for a live sibling first. That is why a lock file we cannot even open
/// fails **open** (returns `true`) instead of terminating a launch that is very likely
/// legitimate: the app is sandboxed with a single home exception for `/.orbit/`, so an
/// `open()` failure means a broken environment, not a running twin. What changes here is that
/// it no longer fails open *silently*, and that only `EWOULDBLOCK` — the one `flock` error that
/// actually means "another process holds this lock" — is reported as a lost race.
enum InstanceLock {
    private static let logger = Logger(subsystem: "com.orbit.access", category: "InstanceLock")
    private static var fd: Int32 = -1

    /// Returns `false` only when another process is known to hold the lock.
    static func acquire(at url: URL = OrbitPaths.accessAppLockURL) -> Bool {
        // Already held by this process: re-acquiring would leak the previous descriptor.
        guard fd < 0 else { return true }

        try? OrbitPaths.ensureOrbitDirectoryExists()
        let newFD = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard newFD >= 0 else {
            let code = errno
            logger.error(
                "instance lock unavailable at \(url.path, privacy: .public): open() failed with errno \(code, privacy: .public) — falling back to the NSRunningApplication check for single-instance protection"
            )
            return true
        }

        if flock(newFD, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(newFD)
            guard code == EWOULDBLOCK else {
                logger.error(
                    "instance lock could not be taken at \(url.path, privacy: .public): flock() failed with errno \(code, privacy: .public) — not a contended lock, so this launch continues"
                )
                return true
            }
            return false
        }

        fd = newFD
        return true
    }

    static func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}
