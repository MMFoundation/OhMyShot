import Foundation
import OMSCore

/// Where recordings are written while they run, and what a crash left there.
///
/// Each recording in progress is a movie written in fragments plus a small record of when it began and what
/// was in front. A finished recording leaves nothing here; anything found at launch was cut short, and is
/// readable up to its last fragment, so it can still be finished and kept.
public struct RecordingDrafts: Sendable {
    /// What is known about a recording before it is finished.
    public struct Info: Codable, Equatable, Sendable {
        public var startedAt: Date
        /// The app that was in front when recording began, for the file's name.
        public var appName: String?
        /// What it is kept as; nil (a draft from before GIFs) is a movie.
        public var output: RecordingOutput?
        /// The recorded display's pixels per point, which sizes a GIF as things were on screen.
        public var pixelsPerPoint: Double?

        public init(startedAt: Date, appName: String?, output: RecordingOutput = .video, pixelsPerPoint: Double? = nil) {
            self.startedAt = startedAt
            self.appName = appName
            self.output = output
            self.pixelsPerPoint = pixelsPerPoint
        }
    }

    /// Minimum free space required on the draft volume before starting a recording (500 MiB).
    public static let minimumFreeBytesToStart: Int64 = 500 * 1_024 * 1_024
    /// Minimum free space kept while recording; dropping below this stops early so finishing still has room (250 MiB).
    public static let minimumFreeBytesWhileRecording: Int64 = 250 * 1_024 * 1_024

    public enum DiskSpaceStatus: Equatable, Sendable {
        case sufficient(availableBytes: Int64?)
        case insufficient(availableBytes: Int64, requiredBytes: Int64)
    }

    /// One recording in progress, or left behind.
    public struct Draft: Equatable, Sendable {
        public let id: UUID
        public let movieURL: URL
        public let info: Info?

        /// Where a Studio recording's camera is written beside it, in a movie of its own.
        public var cameraURL: URL {
            movieURL.deletingPathExtension().appendingPathExtension("camera.mov")
        }

        /// Where a Studio recording's telemetry checkpoint is written beside it.
        public var telemetryURL: URL {
            movieURL.deletingPathExtension().appendingPathExtension("telemetry.json")
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The standard location: Application Support, under this build's bundle identifier.
    public static func standard() -> RecordingDrafts {
        RecordingDrafts(directory: AppFolders.support.appending(path: "Recordings in Progress", directoryHint: .isDirectory))
    }

    /// Checks free space on the volume hosting the drafts folder. Uses the nearest existing ancestor when
    /// the drafts folder has not been created yet.
    public func checkDiskSpace(
        requiring minimumBytes: Int64,
        measure: (URL) -> Int64? = Self.volumeAvailableBytes(at:)
    ) -> DiskSpaceStatus {
        let probe = Self.existingAncestor(of: directory)
        guard let available = measure(probe) else { return .sufficient(availableBytes: nil) }
        if available < minimumBytes {
            return .insufficient(availableBytes: available, requiredBytes: minimumBytes)
        }
        return .sufficient(availableBytes: available)
    }

    public static func volumeAvailableBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return values.volumeAvailableCapacity.map { Int64($0) }
    }

    private static func existingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path(percentEncoded: false)) {
            let parent = current.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == current.path(percentEncoded: false) { break }
            current = parent
        }
        return current
    }

    /// Makes room for a new recording and notes when it began. The movie is written at the draft's URL.
    public func create(_ info: Info, id: UUID = UUID()) throws -> Draft {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let draft = Draft(id: id, movieURL: directory.appending(path: "\(id.uuidString).mov"), info: info)
        try JSONEncoder.drafts.encode(info).write(to: infoURL(for: id), options: .atomic)
        return draft
    }

    /// Removes a draft, its movies, its telemetry checkpoint, and its record.
    public func remove(_ draft: Draft) {
        try? FileManager.default.removeItem(at: draft.movieURL)
        try? FileManager.default.removeItem(at: draft.cameraURL)
        try? FileManager.default.removeItem(at: draft.telemetryURL)
        try? FileManager.default.removeItem(at: infoURL(for: draft.id))
    }

    /// The drafts on disk except `excluding` (those still recording), oldest first. A record whose movie never
    /// got written is removed on the way.
    public func leftovers(excluding: Set<UUID> = []) -> [Draft] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return [] }
        var drafts: [Draft] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !excluding.contains(id) else { continue }
            let movie = directory.appending(path: "\(id.uuidString).mov")
            let info = FileManager.default.contents(atPath: infoURL(for: id).path(percentEncoded: false))
                .flatMap { try? JSONDecoder.records.decode(Info.self, from: $0) }
            guard FileManager.default.fileExists(atPath: movie.path(percentEncoded: false)) else {
                try? FileManager.default.removeItem(at: infoURL(for: id))
                continue
            }
            drafts.append(Draft(id: id, movieURL: movie, info: info))
        }
        for name in names where name.hasSuffix(".mov") {
            // A movie without its record still holds a recording.
            guard let id = UUID(uuidString: String(name.dropLast(4))), !excluding.contains(id), !drafts.contains(where: { $0.id == id }) else { continue }
            drafts.append(Draft(id: id, movieURL: directory.appending(path: name), info: nil))
        }
        return drafts.sorted { ($0.info?.startedAt ?? .distantPast) < ($1.info?.startedAt ?? .distantPast) }
    }

    private func infoURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}

/// A draft's notes are written compact, without the pretty printing of the records `JSONEncoder.records` writes; they
/// are read back as those are (`JSONDecoder.records`).
private extension JSONEncoder {
    static var drafts: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
