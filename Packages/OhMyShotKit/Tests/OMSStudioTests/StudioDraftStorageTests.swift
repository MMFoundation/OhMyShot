import Foundation
import OMSCore
import Testing
@testable import OMSStudio

struct StudioDraftStorageTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "StudioDraftStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func incrementalTelemetryCheckpointRetimesWithMovieStartPausesAndCamera() async throws {
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointURL = root.appending(path: "draft.telemetry.json")

        let origin = 1_000.0
        let raw = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [
                .init(time: origin - 0.1, x: 100, y: 100, cursor: 0),
                .init(time: origin + 1.0, x: 400, y: 300, cursor: 0),
                .init(time: origin + 3.0, x: 900, y: 500, cursor: 0), // inside completed pause [1002, 1004]
                .init(time: origin + 5.0, x: 420, y: 310, cursor: 0), // movie time 3.0
                .init(time: origin + 8.5, x: 1200, y: 700, cursor: 0), // inside open pause [1008, ...]
            ],
            clicks: [
                .init(time: origin + 1.0, x: 400, y: 300, button: .primary),
                .init(time: origin + 1.4, x: 410, y: 305, button: .primary),
                .init(time: origin + 5.0, x: 420, y: 310, button: .primary),
                .init(time: origin + 8.6, x: 1200, y: 700, button: .primary),
            ]
        )
        let draft = StudioDraftTelemetry(
            telemetry: raw, isRetimed: false, movieStart: origin,
            pauses: [.init(start: origin + 2.0, end: origin + 4.0), .init(start: origin + 8.0, end: nil)],
            cameraStart: origin - 0.1,
            cameraFills: [.init(time: origin + 1.0, fills: true), .init(time: origin + 5.0, fills: false)],
            cameraBubble: StudioProject.Camera(shape: .roundedSquare, size: 220, corner: .bottomLeft, mirrored: true),
            cameraWanted: true, showsClicks: true, showsKeystrokes: false
        )

        let checkpointer = StudioDraftCheckpointer()
        await checkpointer.checkpoint(draft, to: checkpointURL)
        let firstModified = try checkpointURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // Identical snapshot skips redundant disk write.
        await checkpointer.checkpoint(draft, to: checkpointURL)
        let secondModified = try checkpointURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(firstModified == secondModified)

        let reloaded = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: checkpointURL))
        let resolved = reloaded.resolvedTelemetry(movieDuration: 6.0, hasCameraFile: true)
        // Pause [1002, 1004] cut out and open pause [1008, ...] dropped.
        #expect(resolved.clicks.map(\.time).count == 3)
        #expect(abs(resolved.clicks[0].time - 1.0) < 1e-9)
        #expect(abs(resolved.clicks[1].time - 1.4) < 1e-9)
        #expect(abs(resolved.clicks[2].time - 3.0) < 1e-9)
        #expect(resolved.samples.allSatisfy { $0.time < 6.0 })
        // Recovered telemetry generates Studio auto-zooms.
        #expect(!AutoZoom.zooms(for: resolved, duration: 6.0).isEmpty)
        // Camera offset and fill ranges are aligned to the movie timeline.
        #expect(abs((resolved.camera?.start ?? 0) - (-0.1)) < 1e-9)
        #expect(resolved.camera?.fills == [1.0...3.0])
        #expect(resolved.camera?.bubble.corner == .bottomLeft)
    }

    @Test func aCheckpointThatOnlyAddsReadingsWaitsWhileAPauseIsWrittenAtOnce() async throws {
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "draft.telemetry.json")
        var draft = StudioDraftTelemetry(
            telemetry: StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 1, x: 10, y: 10, cursor: 0)], clicks: []),
            isRetimed: false, movieStart: 1
        )
        let checkpointer = StudioDraftCheckpointer(minimumInterval: .seconds(3600))
        await checkpointer.checkpoint(draft, to: url)
        draft.telemetry.samples.append(.init(time: 2, x: 20, y: 20, cursor: 0))
        await checkpointer.checkpoint(draft, to: url)
        var written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.samples.count == 1)

        draft.pauses.append(.init(start: 3))
        await checkpointer.checkpoint(draft, to: url)
        written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.samples.count == 2)
        #expect(written.pauses.count == 1)
    }

    @Test func dragReleaseWithoutNewSamplesOrClicksIsCheckpointedAfterInterval() async throws {
        let root = temporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "draft.telemetry.json")

        nonisolated final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var current = ContinuousClock.now
            func now() -> ContinuousClock.Instant { lock.withLock { current } }
            func advance(by duration: Duration) { lock.withLock { current += duration } }
        }
        let clock = Clock()
        let checkpointer = StudioDraftCheckpointer(minimumInterval: .seconds(10), now: { clock.now() })

        var draft = StudioDraftTelemetry(
            telemetry: StudioTelemetry(
                width: 1600, height: 1000, pixelsPerPoint: 2,
                samples: [.init(time: 10, x: 200, y: 200, cursor: 0), .init(time: 11, x: 500, y: 300, cursor: 0)],
                clicks: [.init(time: 10, x: 200, y: 200, button: .primary)]
            ),
            isRetimed: false, movieStart: 10
        )
        await checkpointer.checkpoint(draft, to: url)
        var written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.clicks.count == 1)
        #expect(written.telemetry.clicks[0].releaseTime == nil)

        // Mutate the drag release in place: neither click count nor sample count changes.
        draft.telemetry.clicks[0].releaseTime = 11.2
        draft.telemetry.clicks[0].releaseX = 500
        draft.telemetry.clicks[0].releaseY = 300

        // Within the 10 s readings-only throttle, the checkpoint waits.
        clock.advance(by: .seconds(1))
        await checkpointer.checkpoint(draft, to: url)
        written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.clicks[0].releaseTime == nil)

        // Once the throttle passes, the release is written to disk.
        clock.advance(by: .seconds(60))
        await checkpointer.checkpoint(draft, to: url)
        written = try JSONDecoder().decode(StudioDraftTelemetry.self, from: Data(contentsOf: url))
        #expect(written.telemetry.clicks[0].releaseTime == 11.2)
        #expect(written.telemetry.clicks[0].releaseX == 500)
        #expect(written.telemetry.clicks[0].releaseY == 300)
        #expect(written.telemetry.clicks[0].isDrag)
    }

    @Test func studioProjectStorageCopiesCameraAndReportsPartialFailuresWithoutLosingDraft() throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let projectDir = root.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        try Data("camera-bytes".utf8).write(to: draftCamera)
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera())
        )
        let project = StudioProject(zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: true)])

        // Full success: all sidecars written and draft camera stays on disk until caller removes the draft.
        let ok = StudioProjectStorage.save(telemetry: telemetry, project: project, cameraURL: draftCamera, to: projectDir)
        #expect(ok.isComplete)
        #expect(ok.savedCamera && ok.savedTelemetry && ok.savedProject)
        #expect(FileManager.default.fileExists(atPath: draftCamera.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.camera).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.telemetry).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.project).path(percentEncoded: false)))

        // Camera copy failure: reports partial save, keeps draft camera intact, marks written telemetry cameraFailed.
        let cameraFailDir = root.appending(path: "CameraFail", directoryHint: .isDirectory)
        let cameraFail = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: cameraFailDir,
            copyCamera: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        #expect(!cameraFail.isComplete)
        #expect(cameraFail.expectedCamera && !cameraFail.savedCamera)
        #expect(cameraFail.savedTelemetry && cameraFail.savedProject)
        #expect(cameraFail.errorDescription != nil)
        #expect(FileManager.default.fileExists(atPath: draftCamera.path(percentEncoded: false)))
        let fallbackTelemetry = try JSONDecoder().decode(
            StudioTelemetry.self, from: Data(contentsOf: cameraFailDir.appending(path: StudioFiles.telemetry))
        )
        #expect(fallbackTelemetry.camera == nil)
        #expect(fallbackTelemetry.cameraFailed == true)

        // Telemetry JSON write failure: reports incomplete so caller preserves the draft.
        let telemetryFailDir = root.appending(path: "TelemetryFail", directoryHint: .isDirectory)
        let telemetryFail = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: telemetryFailDir,
            writeData: { data, url in
                if url.lastPathComponent == StudioFiles.telemetry { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        #expect(!telemetryFail.isComplete)
        #expect(!telemetryFail.savedTelemetry && telemetryFail.savedProject && telemetryFail.savedCamera)

        // Project JSON write failure: reports incomplete so caller preserves the draft.
        let projectFailDir = root.appending(path: "ProjectFail", directoryHint: .isDirectory)
        let projectFail = StudioProjectStorage.save(
            telemetry: telemetry, project: project, cameraURL: draftCamera, to: projectFailDir,
            writeData: { data, url in
                if url.lastPathComponent == StudioFiles.project { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        #expect(!projectFail.isComplete)
        #expect(projectFail.savedTelemetry && !projectFail.savedProject && projectFail.savedCamera)
    }

    @Test func partialStudioSaveRecoversMissingAssetsIntoExistingHistoryEntryWithoutDuplicating() async throws {
        let root = temporaryFolder()
        let draftDir = root.appending(path: "Draft", directoryHint: .isDirectory)
        let historyDir = root.appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryStore(directory: historyDir)
        let finishedMovie = root.appending(path: "recording.mp4")
        try Data("mp4-bytes".utf8).write(to: finishedMovie)
        let entry = try history.add(
            movingFileAt: finishedMovie, name: "Studio Clip", kind: .recording,
            pixelWidth: 1600, pixelHeight: 1000, appName: "Xcode", duration: 6.0, pixelsPerPoint: 2
        )

        let draftCamera = draftDir.appending(path: "clip.camera.mov")
        let draftTelemetryURL = draftDir.appending(path: "clip.telemetry.json")
        try Data("camera-bytes".utf8).write(to: draftCamera)

        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 400, y: 300, cursor: 0)],
            clicks: [.init(time: 1.0, x: 400, y: 300, button: .primary), .init(time: 1.5, x: 410, y: 305, button: .primary)],
            camera: .init(start: 0, fills: [], bubble: StudioProject.Camera(corner: .bottomLeft))
        )
        let draftTelemetry = StudioDraftTelemetry(
            telemetry: telemetry, isRetimed: true, movieStart: 100,
            cameraStart: 100, cameraBubble: StudioProject.Camera(corner: .bottomLeft),
            cameraWanted: true, showsClicks: true, showsKeystrokes: false
        )
        try JSONEncoder().encode(draftTelemetry).write(to: draftTelemetryURL, options: .atomic)

        // Simulate initial partial save: camera copy failed (disk full), telemetry saved with cameraFailed,
        // project saved, and the user subsequently edited the saved project's zooms.
        let projectDir = history.studioURL(for: entry)
        let initialProject = StudioProject(zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: true)])
        let partial = StudioProjectStorage.save(
            telemetry: telemetry, project: initialProject, cameraURL: draftCamera, to: projectDir,
            copyCamera: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        #expect(!partial.isComplete)
        #expect(!partial.savedCamera && partial.savedTelemetry && partial.savedProject)

        var userEditedProject = initialProject
        userEditedProject.zooms = [.init(start: 2, end: 5, scale: 1.75, isAutomatic: false)]
        try JSONEncoder().encode(userEditedProject).write(to: projectDir.appending(path: StudioFiles.project), options: .atomic)

        // Recovery retries into the existing History entry: copies camera, updates telemetry with camera
        // restored, preserves user-edited project.json, and adds no duplicate History item.
        var copyCount = 0
        var writtenFiles: [String] = []
        let outcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
            copyCamera: { source, destination in
                copyCount += 1
                try FileManager.default.copyItem(at: source, to: destination)
            },
            writeData: { data, destination in
                writtenFiles.append(destination.lastPathComponent)
                try data.write(to: destination, options: .atomic)
            }
        )

        #expect(history.items().count == 1)
        #expect(history.items().first?.id == entry.id)
        guard case .completed(let result) = outcome else {
            Issue.record("Expected completed recovery, got \(outcome)")
            return
        }
        #expect(result.isComplete)
        #expect(copyCount == 1)
        #expect(writtenFiles == [StudioFiles.telemetry])
        #expect(FileManager.default.fileExists(atPath: projectDir.appending(path: StudioFiles.camera).path(percentEncoded: false)))

        let recoveredTelemetry = try JSONDecoder().decode(
            StudioTelemetry.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.telemetry))
        )
        #expect(recoveredTelemetry.camera != nil)
        #expect(recoveredTelemetry.cameraFailed != true)

        let preservedProject = try JSONDecoder().decode(
            StudioProject.self, from: Data(contentsOf: projectDir.appending(path: StudioFiles.project))
        )
        #expect(preservedProject.zooms == userEditedProject.zooms)

        // Second scenario: only project.json failed originally; recovery writes only project.json and
        // does not re-copy camera.mov or overwrite telemetry.json.
        try FileManager.default.removeItem(at: projectDir.appending(path: StudioFiles.project))
        copyCount = 0
        writtenFiles = []
        let projectOnlyOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
            copyCamera: { source, destination in
                copyCount += 1
                try FileManager.default.copyItem(at: source, to: destination)
            },
            writeData: { data, destination in
                writtenFiles.append(destination.lastPathComponent)
                try data.write(to: destination, options: .atomic)
            }
        )
        guard case .completed(let projectOnlyResult) = projectOnlyOutcome else {
            Issue.record("Expected completed project-only recovery, got \(projectOnlyOutcome)")
            return
        }
        #expect(projectOnlyResult.isComplete)
        #expect(copyCount == 0)
        #expect(writtenFiles == [StudioFiles.project])
        #expect(history.items().count == 1)

        // Third scenario: if the user deleted the history entry before next launch, recovery discards
        // the orphaned draft cleanly without creating any History entry.
        history.delete(entry)
        let deletedOutcome = await StudioProjectStorage.recoverMissingAssets(
            forHistoryID: entry.id,
            telemetryURL: draftTelemetryURL,
            cameraURL: draftCamera,
            in: history,
            hasReadableVideo: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        )
        #expect(deletedOutcome == .discarded)
        #expect(history.items().isEmpty)
    }
}
