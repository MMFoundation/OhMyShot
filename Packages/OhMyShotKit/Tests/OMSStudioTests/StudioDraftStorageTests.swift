import Foundation
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
}
