import AVFoundation
import Foundation

/// One of a Studio recording's sounds, set on its own in the movie. The system's sound and the microphone are
/// recorded in tracks of their own; the history keeps the recording with them mixed into one, which every player
/// plays, and Studio keeps each in a file of its own beside the project. A recording kept before that has its
/// sound as one, in the recording itself.
nonisolated public enum StudioSound: String, CaseIterable, Sendable {
    case system
    case microphone
    /// The recording's own sound, as one: what is played where the sounds weren't kept apart.
    case recorded

    /// Its file in the project folder; nil for the recording's own sound.
    var fileName: String? {
        switch self {
        case .system: StudioFiles.systemAudio
        case .microphone: StudioFiles.microphone
        case .recorded: nil
        }
    }

    /// The sounds kept apart in `folder`, in order, with their files.
    static func files(in folder: URL) -> [(sound: StudioSound, url: URL)] {
        allCases.compactMap { sound in
            guard let name = sound.fileName else { return nil }
            let url = folder.appending(path: name)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? (sound, url) : nil
        }
    }

    /// Whether `folder` keeps a recording's sounds apart.
    public static func areKept(in folder: URL) -> Bool {
        !files(in: folder).isEmpty
    }

    /// Which sound each of a recording's audio tracks holds, from their channels, in order: the recorder writes the
    /// system's sound first, in stereo, then the microphone, in mono. Nil for tracks it never writes.
    static func sounds(ofTracksWithChannels channels: [Int]) -> [StudioSound]? {
        switch channels.count {
        case 0: []
        case 1: channels[0] == 1 ? [.microphone] : [.system]
        case 2: [.system, .microphone]
        default: nil
        }
    }

    /// Keeps each sound of `movie` (the movie written while recording) in its file in `folder`, copied as it was
    /// encoded, on the movie's timeline, so Studio plays it in step with the recording. A file is in place only once
    /// it is whole. Returns the sounds kept: none when the movie has no sound, or tracks the recorder never writes.
    @concurrent public static func keep(from movie: URL, in folder: URL) async throws -> [StudioSound] {
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var channels: [Int] = []
        for track in tracks {
            let description = try await track.load(.formatDescriptions).first
            channels.append(Int(description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0))
        }
        guard let sounds = sounds(ofTracksWithChannels: channels), !sounds.isEmpty else { return [] }
        let end = try await asset.load(.duration)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (track, sound) in zip(tracks, sounds) {
            guard let name = sound.fileName else { continue }
            let destination = folder.appending(path: name)
            let partial = folder.appending(path: ".\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await copy(track, of: asset, endingAt: end, to: partial)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        return sounds
    }

    /// Writes `track` of `asset` alone to an M4A at `destination`, as it was encoded, from the movie's start to `end`.
    private static func copy(_ track: AVAssetTrack, of asset: AVAsset, endingAt end: CMTime, to destination: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: try await track.load(.formatDescriptions).first)
        writer.add(input)
        guard reader.startReading() else { throw StudioError.readingFailed(String(describing: reader.error)) }
        guard writer.startWriting() else { throw StudioError.writingFailed(String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)
        await Pump(output: output, input: input, label: "studio.sound").run()
        guard reader.status != .failed else {
            writer.cancelWriting()
            throw StudioError.readingFailed(String(describing: reader.error))
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.writingFailed(String(describing: writer.error)) }
    }
}
