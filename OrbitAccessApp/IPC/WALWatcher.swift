import Foundation
import Dispatch

final class WALWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.orbit.access.wal-watcher")
    private var onChangeHandler: (() -> Void)?

    func start(walURL: URL, onChange: @escaping () -> Void) {
        stop()
        onChangeHandler = onChange
        fileDescriptor = open(walURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.onChangeHandler?()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        onChangeHandler = nil
    }

    deinit {
        stop()
    }
}
