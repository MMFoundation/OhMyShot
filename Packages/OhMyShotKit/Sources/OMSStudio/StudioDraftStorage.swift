import Foundation
import OMSCore
import OSLog

/// What a Studio recording keeps beside its draft movie so a crash, forced quit, or partial save failure
/// can recover the recording into Studio with its cursor, clicks, keys, and camera aligned to the movie.
nonisolated public struct StudioDraftTelemetry: Codable, Equatable, Sendable {
    public struct Pause: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double?

        public init(start: Double, end: Double? = nil) {
            self.start = start
            self.end = end
        }
    }

    public struct CameraFillChange: Codable, Equatable, Sendable {
        public var time: Double
        public var fills: Bool

        public init(time: Double, fills: Bool) {
            self.time = time
            self.fills = fills
        }
    }

    /// Raw host-clock telemetry while recording (`isRetimed == false`), or movie-timeline telemetry once
    /// stopped (`isRetimed == true`).
    public var telemetry: StudioTelemetry
    public var isRetimed: Bool
    /// Host-clock seconds of the screen movie's first frame.
    public var movieStart: Double?
    /// Pause intervals in host-clock seconds (an open pause has `end == nil`).
    public var pauses: [Pause]
    /// Host-clock seconds of the camera movie's first frame, when a camera movie is recorded.
    public var cameraStart: Double?
    public var cameraFills: [CameraFillChange]
    public var cameraBubble: StudioProject.Camera?
    public var cameraWanted: Bool
    public var showsClicks: Bool
    public var showsKeystrokes: Bool

    public init(
        telemetry: StudioTelemetry,
        isRetimed: Bool,
        movieStart: Double? = nil,
        pauses: [Pause] = [],
        cameraStart: Double? = nil,
        cameraFills: [CameraFillChange] = [],
        cameraBubble: StudioProject.Camera? = nil,
        cameraWanted: Bool = false,
        showsClicks: Bool = true,
        showsKeystrokes: Bool = true
    ) {
        self.telemetry = telemetry
        self.isRetimed = isRetimed
        self.movieStart = movieStart
        self.pauses = pauses
        self.cameraStart = cameraStart
        self.cameraFills = cameraFills
        self.cameraBubble = cameraBubble
        self.cameraWanted = cameraWanted
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
    }

    /// Resolves this draft telemetry onto the finished movie's timeline (`0...movieDuration`).
    public func resolvedTelemetry(movieDuration: Double, hasCameraFile: Bool) -> StudioTelemetry {
        if isRetimed {
            var resolved = telemetry
            if resolved.camera != nil, !hasCameraFile {
                resolved.camera = nil
                resolved.cameraFailed = true
            }
            return resolved
        }
        var raw = TelemetryRecorder.ordered(telemetry)
        let start = movieStart ?? Self.earliestHostTime(in: raw) ?? 0
        var ranges: [ClosedRange<Double>] = pauses.compactMap { pause in
            guard let end = pause.end, end > pause.start else { return nil }
            return pause.start...end
        }
        let completedPaused = ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let openPauseStart = pauses.last.flatMap { $0.end == nil ? $0.start : nil }
        if let openPauseStart {
            ranges.append(openPauseStart...Double.greatestFiniteMagnitude)
        }
        let endHost = openPauseStart ?? (start + max(0, movieDuration) + completedPaused)
        if hasCameraFile {
            var fills: [ClosedRange<Double>] = []
            var since: Double?
            for change in cameraFills {
                if change.fills, since == nil { since = change.time }
                if !change.fills, let began = since {
                    if change.time > began { fills.append(began...change.time) }
                    since = nil
                }
            }
            if let began = since, endHost > began { fills.append(began...endHost) }
            raw.camera = StudioTelemetry.Camera(
                start: cameraStart ?? start, fills: fills, bubble: cameraBubble ?? StudioProject.Camera()
            )
        } else if cameraWanted {
            raw.cameraFailed = true
        }
        return raw.retimed(start: start, pauses: ranges)
    }

    private static func earliestHostTime(in telemetry: StudioTelemetry) -> Double? {
        [telemetry.samples.first?.time, telemetry.clicks.first?.time, telemetry.keys.first?.time]
            .compactMap(\.self)
            .min()
    }
}

/// Serializes incremental Studio telemetry checkpoints off the main actor so recording stays responsive
/// and a crash or forced quit still leaves usable pointer/zoom/camera metadata in the drafts folder.
public actor StudioDraftCheckpointer {
    private struct Version: Equatable {
        let samples: Int
        let clicks: Int
        let keys: Int
        let cursors: Int
        let movieStart: Double?
        let pauses: Int
        let openPause: Bool
        let cameraStart: Double?
        let cameraFills: Int

        /// Whether the movie's timeline (its start, pauses, and camera) is as in `other`, so only new pointer
        /// readings, clicks, or keys are left to write.
        func hasTimeline(of other: Version) -> Bool {
            movieStart == other.movieStart && pauses == other.pauses && openPause == other.openPause
                && cameraStart == other.cameraStart && cameraFills == other.cameraFills
        }
    }

    private var lastVersion: Version?
    private var isStopped = false
    private let minimumInterval: Duration
    private var nextWrite: ContinuousClock.Instant?

    /// Each checkpoint writes everything recorded so far, so one that only adds readings waits at least
    /// `minimumInterval`, and fifty times as long as the last write took, keeping a long recording's
    /// checkpoints to a small share of a core.
    public init(minimumInterval: Duration = .seconds(10)) {
        self.minimumInterval = minimumInterval
    }

    /// Writes an incremental checkpoint atomically to `url` when the recording's telemetry state changed.
    public func checkpoint(_ draft: StudioDraftTelemetry, to url: URL) {
        guard !isStopped else { return }
        let version = Version(
            samples: draft.telemetry.samples.count,
            clicks: draft.telemetry.clicks.count,
            keys: draft.telemetry.keys.count,
            cursors: draft.telemetry.cursors.count,
            movieStart: draft.movieStart,
            pauses: draft.pauses.count,
            openPause: draft.pauses.last?.end == nil && !draft.pauses.isEmpty,
            cameraStart: draft.cameraStart,
            cameraFills: draft.cameraFills.count
        )
        guard version != lastVersion else { return }
        let clock = ContinuousClock()
        if let lastVersion, version.hasTimeline(of: lastVersion), let nextWrite, clock.now < nextWrite { return }
        let began = clock.now
        var normalized = draft
        if !normalized.isRetimed {
            normalized.telemetry = TelemetryRecorder.ordered(normalized.telemetry)
        }
        do {
            try JSONEncoder().encode(normalized).write(to: url, options: .atomic)
            lastVersion = version
            nextWrite = clock.now + max(minimumInterval, began.duration(to: clock.now) * 50)
        } catch {
            Log.studio.error("Writing Studio telemetry checkpoint failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes the finalized draft telemetry and suppresses any further periodic checkpoints.
    public func saveFinal(_ draft: StudioDraftTelemetry, to url: URL) throws {
        isStopped = true
        var normalized = draft
        if !normalized.isRetimed {
            normalized.telemetry = TelemetryRecorder.ordered(normalized.telemetry)
        }
        try JSONEncoder().encode(normalized).write(to: url, options: .atomic)
    }

    /// Stops any queued checkpoints from writing after a recording is discarded.
    public func cancel() {
        isStopped = true
    }
}

/// Outcome of persisting a Studio project's sidecar assets beside the kept screen recording.
nonisolated public struct StudioProjectSaveResult: Equatable, Sendable {
    public var savedTelemetry: Bool
    public var savedProject: Bool
    public var expectedCamera: Bool
    public var savedCamera: Bool
    public var errorDescription: String?

    public var isComplete: Bool {
        savedTelemetry && savedProject && (!expectedCamera || savedCamera)
    }

    public init(
        savedTelemetry: Bool,
        savedProject: Bool,
        expectedCamera: Bool,
        savedCamera: Bool,
        errorDescription: String? = nil
    ) {
        self.savedTelemetry = savedTelemetry
        self.savedProject = savedProject
        self.expectedCamera = expectedCamera
        self.savedCamera = savedCamera
        self.errorDescription = errorDescription
    }
}

/// Persists Studio sidecar assets (`camera.mov`, `telemetry.json`, `project.json`) non-destructively so
/// the caller only deletes the source draft when every expected asset landed cleanly.
nonisolated public enum StudioProjectStorage {
    public static func save(
        telemetry: StudioTelemetry,
        project: StudioProject,
        cameraURL: URL?,
        to folder: URL,
        copyCamera: (URL, URL) throws -> Void = { source, destination in
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        },
        writeData: (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    ) -> StudioProjectSaveResult {
        let expectsCamera = telemetry.camera != nil && cameraURL != nil
        var result = StudioProjectSaveResult(
            savedTelemetry: false, savedProject: false, expectedCamera: expectsCamera, savedCamera: false
        )
        var errors: [String] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            result.errorDescription = error.localizedDescription
            return result
        }

        var writtenTelemetry = telemetry
        if expectsCamera, let cameraURL {
            do {
                try copyCamera(cameraURL, folder.appending(path: StudioFiles.camera))
                result.savedCamera = true
            } catch {
                errors.append(error.localizedDescription)
                writtenTelemetry.camera = nil
                writtenTelemetry.cameraFailed = true
            }
        }

        do {
            let data = try JSONEncoder().encode(writtenTelemetry)
            try writeData(data, folder.appending(path: StudioFiles.telemetry))
            result.savedTelemetry = true
        } catch {
            errors.append(error.localizedDescription)
        }

        do {
            let data = try JSONEncoder().encode(project)
            try writeData(data, folder.appending(path: StudioFiles.project))
            result.savedProject = true
        } catch {
            errors.append(error.localizedDescription)
        }

        if !errors.isEmpty {
            result.errorDescription = errors.joined(separator: "; ")
        }
        return result
    }
}
