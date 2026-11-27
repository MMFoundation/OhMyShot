import AppKit
import Foundation

/// A copied recording is a file reference. Timed history checks it on demand; only Never needs to notice
/// the clipboard changing while the app is idle, using event-driven workspace observers with zero timers or
/// idle wakeups.
@MainActor
public final class RecordingClipboardHold {
    @MainActor
    final class Watch: Equatable {
        private let center: NotificationCenter
        private var observers: [any NSObjectProtocol]
        private(set) var isCancelled = false

        init(center: NotificationCenter, onEvent: @escaping @MainActor @Sendable () -> Void) {
            self.center = center
            let names: [Notification.Name] = [
                NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
            ]
            self.observers = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { onEvent() }
                }
            }
        }

        isolated deinit {
            cancel()
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            for observer in observers {
                center.removeObserver(observer)
            }
            observers.removeAll()
        }

        nonisolated static func == (lhs: Watch, rhs: Watch) -> Bool {
            lhs === rhs
        }
    }

    private let changeCount: () -> Int
    private let released: (UUID) -> Void
    private let notificationCenter: NotificationCenter
    private var recordings: (ids: Set<UUID>, changeCount: Int)?
    private(set) var watch: Watch?

    public init(
        changeCount: @escaping () -> Int,
        released: @escaping (UUID) -> Void,
        notificationCenter: NotificationCenter? = nil
    ) {
        self.changeCount = changeCount
        self.released = released
        self.notificationCenter = notificationCenter ?? NSWorkspace.shared.notificationCenter
    }

    isolated deinit {
        stopWatching()
    }

    public var heldIDs: Set<UUID> {
        guard let recordings, recordings.changeCount == changeCount() else { return [] }
        return recordings.ids
    }

    public var heldID: UUID? {
        heldIDs.first
    }

    public func copied(_ id: UUID, retention: HistoryRetention) {
        copied([id], retention: retention)
    }

    public func copied(_ ids: Set<UUID>, retention: HistoryRetention) {
        let former = recordings?.ids ?? []
        recordings = ids.isEmpty ? nil : (ids, changeCount())
        updatePolling(for: retention)
        for id in former where !ids.contains(id) {
            released(id)
        }
    }

    /// Starts or stops event-driven clipboard observation for `retention`, and opportunistically releases any
    /// tracked recording that has already left the clipboard under `.never`.
    public func updatePolling(for retention: HistoryRetention) {
        guard retention == .never, let recordings else {
            stopWatching()
            return
        }
        if heldIDs.isEmpty {
            self.recordings = nil
            stopWatching()
            for id in recordings.ids { released(id) }
            return
        }
        guard watch == nil else { return }
        watch = Watch(center: notificationCenter) { [weak self] in
            self?.poll()
        }
    }

    /// Opportunistically checks whether the tracked recording has left the clipboard (e.g. from
    /// `releaseIfUnheld` or `removeExpired`), stopping observation and notifying `released` if so.
    public func check() {
        guard let recordings, heldIDs.isEmpty else { return }
        self.recordings = nil
        stopWatching()
        for id in recordings.ids { released(id) }
    }

    func poll() {
        guard watch != nil, let recordings, heldIDs.isEmpty else { return }
        self.recordings = nil
        stopWatching()
        for id in recordings.ids { released(id) }
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
    }
}
