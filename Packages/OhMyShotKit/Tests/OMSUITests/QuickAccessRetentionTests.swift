import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
struct QuickAccessRetentionTests {
    private func fixture(
        configure: (inout QuickAccessController.Actions) -> Void = { _ in },
        _ run: (QuickAccessController, () throws -> QuickAccessItem) throws -> Void
    ) throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let thumbnail = try #require(context.makeImage())
        var actions = QuickAccessController.Actions(
            copy: { _ in false }, save: { _, _ in nil }, saveAs: { _ in nil },
            open: { _ in }, annotate: { _ in }, reveal: { _ in }, recognizeText: { _ in },
            pin: { _ in false }, moveToTrash: { _ in }, closed: { item in
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: item.fileURL) }
            }
        )
        configure(&actions)
        try run(QuickAccessController(actions: actions)) {
            let id = UUID(), url = folder.appending(path: id.uuidString)
            try Data().write(to: url)
            return QuickAccessItem(id: id, fileURL: url, thumbnail: thumbnail, pixelWidth: 1, pixelHeight: 1, displayID: 0)
        }
    }

    @Test(arguments: [false, true])
    func displacedCardRestoresUntilExplicitlyClosed(byHeight: Bool) throws {
        try fixture { cards, make in
            let first = try make(), second = try make()
            cards.maximumCards = byHeight ? 2 : 1
            cards.insertIntoStack(first)
            cards.insertIntoStack(second)
            if byHeight { cards.fitStack(to: 1, size: .medium) }
            #expect(cards.itemIDs == [second.id])
            #expect(cards.heldCaptureIDs(for: .never) == [first.id, second.id])
            #expect(cards.canRestoreRecentlyClosed)

            cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            #expect(cards.item(first.id) != nil)
            cards.dismiss(first.id)
            #expect(!cards.heldCaptureIDs(for: .never).contains(first.id))
            #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
            #expect(cards.takeRecentlyClosed()?.id == (byHeight ? nil : second.id))
        }
    }

    @Test func overflowAndTerminationReleaseDisplacedCardsButNotVisibleOnes() throws {
        try fixture { cards, make in
            cards.maximumCards = 1
            let items = try (0..<22).map { _ in try make() }
            items.forEach(cards.insertIntoStack)
            #expect(cards.heldCaptureIDs(for: .never) == Set(items.dropFirst().map(\.id)))
            #expect(!FileManager.default.fileExists(atPath: items[0].fileURL.path))
            cards.finishTrashingNow()
            #expect(cards.heldCaptureIDs(for: .never) == [items[21].id])
            #expect(!cards.canRestoreRecentlyClosed)
            #expect(items.dropLast().allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
            #expect(FileManager.default.fileExists(atPath: items[21].fileURL.path))
        }
    }

    @Test func readdingOrRemovingADisplacedCardForgetsItsRestoreHold() throws {
        try fixture { cards, make in
            cards.maximumCards = 1
            let first = try make(), second = try make()
            cards.insertIntoStack(first)
            cards.insertIntoStack(second)
            cards.insertIntoStack(first)
            cards.remove(second.id)
            cards.dismissAll()
            #expect(cards.heldCaptureIDs(for: .never).isEmpty)
            #expect(!cards.canRestoreRecentlyClosed)
            #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
            #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        }
    }

    @Test func failedTrashKeepsItsCardPastTheAutoCloseDeadline() throws {
        var closed: [UUID] = []
        try fixture(configure: { actions in
            actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .close) }
            actions.moveToTrash = { _ in throw CocoaError(.fileWriteNoPermission) }
            actions.closed = { closed.append($0.id) }
        }) { cards, make in
            let failed = try make(), other = try make()
            cards.insertIntoStack(failed)
            cards.insertIntoStack(other)
            cards.showTrashFailure = { _ in }
            cards.perform(.moveToTrash, on: failed, keyed: false)
            cards.finishTrashingNow()
            cards.closeDueCards(at: .greatestFiniteMagnitude)
            #expect(closed == [other.id])
            #expect(cards.itemIDs == [failed.id])
        }
    }

    @Test func restoredCardUsesTheExportSavedWhileDisplacedForRevealAndTrash() throws {
        var revealed: URL?, trashedCopy: URL?
        try fixture(configure: { actions in
            actions.reveal = { revealed = $0.savedURL ?? $0.fileURL }
            actions.moveToTrash = { trashedCopy = $0.savedURL }
        }) { cards, make in
            let old = try make(), newer = try make()
            let folder = old.fileURL.deletingLastPathComponent(), export = folder.appending(path: "edited.png")
            cards.maximumCards = 1
            cards.insertIntoStack(old)
            cards.markSaved(old.id, at: folder.appending(path: "previous.png"))
            cards.insertIntoStack(newer)
            cards.markSaved(old.id, at: export)
            cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            let restored = try #require(cards.item(old.id))
            cards.perform(.reveal, on: restored, keyed: false)
            cards.perform(.moveToTrash, on: restored, keyed: false)
            cards.finishTrashingNow()
            #expect(revealed == export)
            #expect(trashedCopy == export)
        }
    }

    @Test func timedHistoryExpiresADisplacedCaptureThatNeverWouldKeep() throws {
        try fixture { cards, make in
            let seed = try make()
            let store = HistoryStore(directory: seed.fileURL.deletingLastPathComponent().appending(path: "history"))
            let now = Date.now, old = now.addingTimeInterval(-2 * 86_400)
            let entries = try ["displaced", "visible"].map { name in
                try store.add(data: Data([0]), name: name, fileExtension: "png", kind: .screenshot,
                              pixelWidth: 1, pixelHeight: 1, appName: nil, date: old)
            }
            cards.maximumCards = 1
            for entry in entries {
                cards.insertIntoStack(QuickAccessItem(entry, fileURL: store.fileURL(for: entry), thumbnail: seed.thumbnail, displayID: 0))
            }
            #expect(store.removeExpired(retention: .never, keeping: cards.heldCaptureIDs(for: .never), now: now) == 0)
            #expect(store.removeExpired(retention: .oneDay, keeping: cards.heldCaptureIDs(for: .oneDay), now: now) == 1)
            #expect(store.items().map(\.id) == [entries[1].id])
            #expect(!cards.canRestoreRecentlyClosed)
        }
    }
}
