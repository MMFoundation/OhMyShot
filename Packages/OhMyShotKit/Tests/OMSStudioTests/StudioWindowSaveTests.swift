import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSStudio

@MainActor
@Suite(.serialized)
struct StudioWindowSaveTests {
    private func window(folder: URL, save: @escaping (URL) -> URL?) -> (StudioWindowController, StudioDocument) {
        let source = folder.appending(path: "source.mp4")
        let document = StudioDocument(
            source: source, telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 1), project: StudioProject(), duration: 1,
            recordingSize: CGSize(width: 160, height: 100), folder: folder, hasBeenExported: true, background: { _, _ in nil }
        )
        document.compositionLoader = { _, _ in throw CancellationError() }
        let controller = StudioWindowController(
            document: document, title: "Studio", swatches: [], movie: nil,
            actions: .init(keep: { _, _ in source }, copy: { _ in }, save: save, progress: { _ in })
        )
        return (controller, document)
    }

    @Test func saveAndSaveAsReportOnlyCompletedExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "StudioWindowSaveTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let saved = folder.appending(path: "saved.mp4")
        var saveResult: URL? = saved
        let (editor, document) = window(folder: folder) { _ in saveResult }
        defer {
            editor.window?.close()
            document.releasePreview()
        }
        var reported: [URL] = []
        editor.onSaved = { reported.append($0) }

        #expect(editor.saveCopy(source) == saved)
        saveResult = nil
        #expect(editor.saveCopy(source) == nil)
        #expect(reported == [saved])

        let canceled = await editor.saveCopyAs(from: source, to: nil)
        if case .some = canceled { #expect(Bool(false), "Canceled Save As reported a result") }
        #expect(reported == [saved])

        let destination = folder.appending(path: "saved-as.mp4")
        let copied = await editor.saveCopyAs(from: source, to: destination)
        guard case .success(let copiedURL)? = copied else {
            #expect(Bool(false), "Save As should complete")
            return
        }
        #expect(copiedURL == destination)
        #expect(reported == [saved, destination])

        let missing = folder.appending(path: "missing.mp4")
        let failed = await editor.saveCopyAs(from: missing, to: folder.appending(path: "failed.mp4"))
        guard case .failure? = failed else {
            #expect(Bool(false), "A failed copy should return an error")
            return
        }
        #expect(reported == [saved, destination])
        try await document.flushSave()
    }
}
