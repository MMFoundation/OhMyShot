import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
struct QuickAccessRetentionTests {
    private func fixture(_ run: (QuickAccessController, () throws -> QuickAccessItem) throws -> Void) throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let thumbnail = try #require(context.makeImage())
        let actions = QuickAccessController.Actions(
            copy: { _ in false }, save: { _, _ in nil }, saveAs: { _ in nil },
            open: { _ in }, annotate: { _ in }, reveal: { _ in }, recognizeText: { _ in },
            pin: { _ in false }, moveToTrash: { _ in }, closed: { item in
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: item.fileURL) }
            }
        )
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
            #expect(cards.heldCaptureIDs == [first.id, second.id])
            #expect(cards.canRestoreRecentlyClosed)

            cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            #expect(cards.item(first.id) != nil)
            cards.dismiss(first.id)
            #expect(!cards.heldCaptureIDs.contains(first.id))
            #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
            #expect(cards.takeRecentlyClosed()?.id == (byHeight ? nil : second.id))
        }
    }

    @Test func overflowAndTerminationReleaseDisplacedCardsButNotVisibleOnes() throws {
        try fixture { cards, make in
            cards.maximumCards = 1
            let items = try (0..<22).map { _ in try make() }
            items.forEach(cards.insertIntoStack)
            #expect(cards.heldCaptureIDs == Set(items.dropFirst().map(\.id)))
            #expect(!FileManager.default.fileExists(atPath: items[0].fileURL.path))
            cards.finishTrashingNow()
            #expect(cards.heldCaptureIDs == [items[21].id])
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
            #expect(cards.heldCaptureIDs.isEmpty)
            #expect(!cards.canRestoreRecentlyClosed)
            #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
            #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        }
    }
}
