import AppKit
import Foundation
import Testing
@testable import OMSUI

@MainActor
@Suite(.serialized)
struct RecordingWindowSaveTests {
    private func window(file: URL, save: @escaping (URL) -> URL?) -> RecordingWindowController {
        RecordingWindowController(
            fileURL: file, title: "Recording", pixelWidth: 1, pixelHeight: 1, pixelsPerPoint: nil, hasOriginal: false,
            actions: .init(keep: { _ in file }, revert: { file }, makeGIF: { _ in }, save: save, copy: { _ in })
        )
    }

    @Test func saveAndSaveAsReportOnlyCompletedExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RecordingWindowSaveTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.mp4")
        try Data([1, 2, 3]).write(to: source)
        let saved = folder.appending(path: "saved.mp4")
        var saveResult: URL? = saved
        let editor = window(file: source) { _ in saveResult }
        defer { editor.window?.close() }
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
    }
}
