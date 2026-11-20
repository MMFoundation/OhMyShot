import AVFoundation
import CoreMedia
import Foundation
import OMSCore
import Testing
@testable import OMSRecording

struct RecordingRecoveryTests {
    @Test func draftsLeftBehindAreFoundOldestFirst() throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let newer = try drafts.create(.init(startedAt: .now, appName: "Safari"))
        let older = try drafts.create(.init(startedAt: .now.addingTimeInterval(-60), appName: nil))
        let running = try drafts.create(.init(startedAt: .now, appName: nil))
        let neverWritten = try drafts.create(.init(startedAt: .now, appName: nil))
        for draft in [newer, older, running] {
            try Data([0]).write(to: draft.movieURL)
        }
        // A Studio recording's camera, beside its draft.
        try Data([0]).write(to: newer.cameraURL)
        // A movie whose record is gone still holds a recording.
        let orphan = drafts.directory.appending(path: "\(UUID().uuidString).mov")
        try Data([0]).write(to: orphan)

        let found = drafts.leftovers(excluding: [running.id])
        #expect(found.map(\.movieURL) == [orphan, older.movieURL, newer.movieURL])
        #expect(found.last?.info?.appName == "Safari")
        // A record without a movie is cleaned up.
        #expect(!drafts.leftovers().contains { $0.id == neverWritten.id })
        drafts.remove(newer)
        #expect(!drafts.leftovers().contains { $0.id == newer.id })
        // The camera's movie is no recording of its own, and goes with its draft.
        #expect(newer.cameraURL.lastPathComponent == "\(newer.id.uuidString).camera.mov")
        #expect(!FileManager.default.fileExists(atPath: newer.cameraURL.path(percentEncoded: false)))
    }

    @Test func aMovieCutShortIsReadableUpToItsLastFragment() async throws {
        let url = TestMedia.temporaryMovie()
        let copy = url.deletingLastPathComponent().appending(path: "cut-\(url.lastPathComponent)")
        let finished = copy.deletingPathExtension().appendingPathExtension("mp4")
        defer { [url, copy, finished].forEach { try? FileManager.default.removeItem(at: $0) } }
        let writer = try TestMedia.writer(url: url, audio: RecordingAudio(system: true, microphone: nil))
        // Five seconds, a frame and its audio at a time: fragments are written every two seconds.
        var audioTime = 0.0
        for index in 0..<150 {
            let seconds = Double(index) / 30
            try await TestMedia.append(TestMedia.frame(at: seconds, gray: UInt8(index % 200 + 20)), to: writer)
            while audioTime < seconds {
                await writer.appendAudio(TestMedia.audio(at: audioTime), to: .systemAudio)
                audioTime += 0.02
            }
        }
        // What a crash would leave: the file as it is while the writer still has it open.
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.copyItem(at: url, to: copy)
        await writer.cancel()

        let asset = AVURLAsset(url: copy)
        let duration = try await asset.load(.duration).seconds
        #expect(duration >= 2, "only \(duration) s readable")
        let movie = try await RecordingFinisher.finish(copy, to: finished)
        #expect(movie.duration >= 2)
        #expect(movie.hasAudio)
        #expect(try await TestMedia.frameCount(of: finished) >= 60)
    }

    @Test func telemetryCheckpointsStayWithTheirDraftAndAreRemovedTogether() throws {
        let drafts = RecordingDrafts(directory: FileManager.default.temporaryDirectory.appending(path: "RecordingDrafts-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = try drafts.create(.init(startedAt: .now, appName: "Xcode", output: .studio))
        try Data([0]).write(to: draft.movieURL)
        try Data([0]).write(to: draft.cameraURL)
        try Data("{\"telemetry\":true}".utf8).write(to: draft.telemetryURL)

        let found = drafts.leftovers()
        #expect(found.count == 1)
        #expect(found[0].id == draft.id)
        #expect(draft.telemetryURL.lastPathComponent == "\(draft.id.uuidString).telemetry.json")

        drafts.remove(draft)
        #expect(!FileManager.default.fileExists(atPath: draft.movieURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: draft.cameraURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: draft.telemetryURL.path(percentEncoded: false)))
        #expect(drafts.leftovers().isEmpty)
    }

    @Test func diskSpaceChecksEnforceStartAndRecordingThresholds() {
        let nonExistent = FileManager.default.temporaryDirectory.appending(path: "Missing-\(UUID().uuidString)/Drafts")
        let drafts = RecordingDrafts(directory: nonExistent)
        var probedURL: URL?
        let lowToStart = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) { url in
            probedURL = url
            return RecordingDrafts.minimumFreeBytesToStart - 1
        }
        #expect(probedURL != nil)
        #expect(FileManager.default.fileExists(atPath: probedURL!.path(percentEncoded: false)))
        #expect(lowToStart == .insufficient(
            availableBytes: RecordingDrafts.minimumFreeBytesToStart - 1,
            requiredBytes: RecordingDrafts.minimumFreeBytesToStart
        ))

        let okToStart = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) { _ in
            RecordingDrafts.minimumFreeBytesToStart
        }
        #expect(okToStart == .sufficient(availableBytes: RecordingDrafts.minimumFreeBytesToStart))

        let lowWhileRecording = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesWhileRecording) { _ in
            RecordingDrafts.minimumFreeBytesWhileRecording - 1024
        }
        #expect(lowWhileRecording == .insufficient(
            availableBytes: RecordingDrafts.minimumFreeBytesWhileRecording - 1024,
            requiredBytes: RecordingDrafts.minimumFreeBytesWhileRecording
        ))

        let unreadable = drafts.checkDiskSpace(requiring: RecordingDrafts.minimumFreeBytesToStart) { _ in nil }
        #expect(unreadable == .sufficient(availableBytes: nil))
    }
}
