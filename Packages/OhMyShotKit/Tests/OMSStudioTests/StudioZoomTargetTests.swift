import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSStudio

/// A zoom aimed at a spot of the recording: kept with the project, held there by the framing whatever the pointer
/// does, inside the recording, and framed alike in the preview and the export whatever the movie's padding, shape,
/// and camera layout.
@MainActor
struct StudioZoomTargetTests {
    private static let width = 1600.0, height = 1000.0

    /// The pointer resting at (200, 800), then crossing to (1400, 150) and clicking there while zoomed.
    private static func telemetry(camera: Bool = false) -> StudioTelemetry {
        let samples = (0...(8 * 60)).map { reading -> StudioTelemetry.Sample in
            let time = Double(reading) / 60
            let t = min(max((time - 2) / 1.5, 0), 1)
            return .init(time: time, x: 200 + 1200 * t, y: 800 - 650 * t, cursor: 0)
        }
        return StudioTelemetry(
            width: width, height: height, pixelsPerPoint: 2, samples: samples,
            clicks: [.init(time: 3.6, x: 1400, y: 150, button: .primary), .init(time: 4.2, x: 1390, y: 160, button: .primary)],
            camera: camera ? .init(start: 0, bubble: StudioProject.Camera()) : nil
        )
    }

    private static func track(target: StudioProject.Zoom.Spot?, scale: Double = 2) -> StudioTrack {
        var project = StudioProject(zooms: [.init(start: 1, end: 6, scale: scale, isAutomatic: false, target: target)])
        project.cursor.hidesWhenIdle = false
        return StudioTrack(telemetry: telemetry(), project: project, duration: 8)
    }

    // MARK: Keeping

    @Test func aZoomSavedBeforeItCouldBeAimedFollowsThePointer() throws {
        let id = UUID()
        let json = #"{"zooms":[{"id":"\#(id.uuidString)","start":1,"end":3,"scale":2,"isAutomatic":false}]}"#
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(json.utf8))
        #expect(project.zooms.count == 1 && project.zooms[0].id == id && project.zooms[0].target == nil)
        // A spot this version can't read follows the pointer rather than losing the project.
        let garbled = #"{"zooms":[{"id":"\#(id.uuidString)","start":1,"end":3,"scale":2,"isAutomatic":false,"target":"top"}]}"#
        let kept = try JSONDecoder().decode(StudioProject.self, from: Data(garbled.utf8))
        #expect(kept.zooms.count == 1 && kept.zooms[0].target == nil && kept.zooms[0].end == 3)
    }

    @Test func theSpotIsKeptWithTheProject() throws {
        let project = StudioProject(zooms: [
            .init(start: 1, end: 3, scale: 2, isAutomatic: false, target: .init(x: 0.25, y: 0.75)),
            .init(start: 4, end: 6, scale: 1.5, isAutomatic: true),
        ])
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(StudioProject.self, from: data) == project)
        // A zoom that follows the pointer writes no spot, so it reads the same in a version that knows none.
        let written = try #require(String(data: data, encoding: .utf8))
        #expect(written.components(separatedBy: "\"target\"").count == 2)
    }

    @Test func aimingAZoomChangesItsMotion() {
        var project = StudioProject(zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: false)])
        let following = StudioMotionKey(project)
        project.zooms[0].target = .init(x: 0.2, y: 0.3)
        let aimed = StudioMotionKey(project)
        #expect(following != aimed)
        project.zooms[0].target = .init(x: 0.6, y: 0.3)
        #expect(StudioMotionKey(project) != aimed)
    }

    // MARK: Framing

    @Test func anAimedZoomHoldsItsSpotWhateverThePointerDoes() {
        let spot = StudioProject.Zoom.Spot(x: 0.3, y: 0.4)
        let aimed = Self.track(target: spot)
        let held = aimed.frames.filter { abs($0.zoom - 2) < 1e-9 }
        #expect(held.count > 400)
        for frame in held {
            #expect(abs(frame.centerX - spot.x * Self.width) < 1e-6 && abs(frame.centerY - spot.y * Self.height) < 1e-6)
        }
        // Coming in and going out it scales about one point, which stays where it is drawn and never slides.
        let pivot = (x: (spot.x * Self.width * 2 - Self.width / 2), y: (spot.y * Self.height * 2 - Self.height / 2))
        for frame in aimed.frames where frame.zoom > 1.001 {
            let drawnX = (pivot.x - frame.centerX) * frame.zoom + Self.width / 2
            let drawnY = (pivot.y - frame.centerY) * frame.zoom + Self.height / 2
            #expect(abs(drawnX - pivot.x) < 1e-6 && abs(drawnY - pivot.y) < 1e-6)
        }
        // Following the pointer, the same zoom goes where the clicks are.
        let following = Self.track(target: nil)
        let last = following.frame(at: 5)
        #expect(last.centerX > 1000 && last.centerY < 400)
    }

    @Test func aSpotNearTheEdgeIsHeldInsideTheRecording() {
        let track = Self.track(target: .init(x: 0.98, y: 0.02))
        let frame = track.frame(at: 3)
        #expect(abs(frame.zoom - 2) < 1e-9)
        #expect(abs(frame.centerX - (Self.width - Self.width / 4)) < 1e-6 && abs(frame.centerY - Self.height / 4) < 1e-6)
    }

    @Test func aimedZoomsMeetingOnOneSpotHandOverWithoutPullingBack() {
        let spot = StudioProject.Zoom.Spot(x: 0.3, y: 0.4)
        let first = StudioProject.Zoom(start: 1, end: 3, scale: 2, isAutomatic: false, target: spot)
        let second = StudioProject.Zoom(start: 3, end: 5, scale: 2, isAutomatic: false, target: spot)
        let telemetry = Self.telemetry()
        let events = AutoZoom.events(in: telemetry)
        let together = StudioTrack.samePlaceHandovers(for: [first, second], events: events, samples: telemetry.samples, width: Self.width, height: Self.height)
        #expect(together[first.id]?.after == 2 && together[second.id]?.before == 2)
        // Aimed far apart, the camera pulls back between them, whatever the pointer did.
        var apart = second
        apart.target = .init(x: 0.9, y: 0.9)
        let pulled = StudioTrack.samePlaceHandovers(for: [first, apart], events: events, samples: telemetry.samples, width: Self.width, height: Self.height)
        #expect(pulled.isEmpty)
    }

    // MARK: Preview and export

    @Test func thePreviewAndTheExportFrameTheSameSpot() throws {
        let telemetry = Self.telemetry(camera: true)
        let spots = [StudioProject.Zoom.Spot(x: 0.3, y: 0.4), .init(x: 0.95, y: 0.05)]
        for spot in spots {
            let zoom = StudioProject.Zoom(start: 1, end: 6, scale: 2, isAutomatic: false, target: spot)
            // Where the zoom's view is centered once fully in, as a spot: the spot, kept inside the recording.
            let corners = (x: min(max(spot.x, 0.25), 0.75), y: min(max(spot.y, 0.25), 0.75))
            for padding in [0, 0.2] {
                for aspect in [StudioProject.Aspect.auto, .widescreen, .square, .vertical] {
                    for layout in [StudioProject.Camera.Layout.pictureInPicture, .sideBySide, .cameraOnly, .screenOnly] {
                        var project = StudioProject(padding: padding, aspect: aspect, zooms: [zoom])
                        project.camera.layout = layout
                        let track = StudioTrack(telemetry: telemetry, project: project, duration: 8)
                        for largestSide in [640.0, 1280, StudioRenderer.largestSide] {
                            let renderer = StudioRenderer(
                                telemetry: telemetry, project: project, duration: 8, recordingSize: CGSize(width: 3200, height: 2000),
                                background: nil, largestSide: largestSide, preparedTrack: track
                            )
                            let view = renderer.view(at: 3)
                            let frame = renderer.layout.frame
                            let middle = renderer.spot(atMovie: CGPoint(x: frame.midX, y: frame.midY), in: view)
                            let label = "\(spot) padding \(padding) \(aspect) \(layout) at \(largestSide)"
                            #expect(abs(middle.x - corners.x) < 1e-6 && abs(middle.y - corners.y) < 1e-6, "\(label): \(middle)")
                            // The spot is drawn at the frame's middle when it fits there, and in the same place on
                            // the frame in every movie when it doesn't.
                            let drawn = renderer.moviePoint(of: spot, in: view)
                            let onFrame = (x: (drawn.x - frame.minX) / frame.width, y: (drawn.y - frame.minY) / frame.height)
                            let expected = (x: 0.5 + (spot.x - corners.x) * 2, y: 0.5 - (spot.y - corners.y) * 2)
                            #expect(abs(onFrame.x - expected.x) < 1e-6 && abs(onFrame.y - expected.y) < 1e-6, "\(label): \(onFrame)")
                        }
                    }
                }
            }
        }
    }

    @Test func aPointOnThePreviewIsTheSpotUnderIt() {
        let telemetry = Self.telemetry()
        let project = StudioProject(padding: 0.1, aspect: .square, zooms: [.init(start: 1, end: 6, scale: 2, isAutomatic: false, target: .init(x: 0.4, y: 0.6))])
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 8, recordingSize: CGSize(width: 3200, height: 2000), background: nil, largestSide: 1280)
        for time in [0.0, 3] {
            let view = renderer.view(at: time)
            for spot in [StudioProject.Zoom.Spot(x: 0.1, y: 0.9), .init(x: 0.5, y: 0.5), .init(x: 0.7, y: 0.2)] {
                let back = renderer.spot(atMovie: renderer.moviePoint(of: spot, in: view), in: view)
                #expect(abs(back.x - spot.x) < 1e-9 && abs(back.y - spot.y) < 1e-9)
            }
        }
        // Unzoomed, the frame's corners are the recording's: the top-left corner on the movie (y up) is its top-left.
        let whole = renderer.view(at: 0)
        let topLeft = renderer.spot(atMovie: CGPoint(x: renderer.layout.frame.minX, y: renderer.layout.frame.maxY), in: whole)
        #expect(abs(topLeft.x) < 1e-9 && abs(topLeft.y) < 1e-9)
        // Through the preview's own fitting of the movie in its view, too.
        let canvas = renderer.layout.canvas
        let movie = StudioZoomAim.movieRect(canvas: canvas, in: CGSize(width: 900, height: 500))
        #expect(abs(movie.height - 500) < 1e-9 && abs(movie.midX - 450) < 1e-9)
        let point = CGPoint(x: 512, y: 133)
        let pixel = StudioZoomAim.moviePoint(point, canvas: canvas, movie: movie)
        let again = StudioZoomAim.viewPoint(pixel, canvas: canvas, movie: movie)
        #expect(abs(again.x - point.x) < 1e-9 && abs(again.y - point.y) < 1e-9)
        // The view's top-left corner of the movie is the movie's top-left pixel, y up.
        let corner = StudioZoomAim.moviePoint(CGPoint(x: movie.minX, y: movie.minY), canvas: canvas, movie: movie)
        #expect(abs(corner.x) < 1e-9 && abs(corner.y - canvas.height) < 1e-9)
    }

    // MARK: Editing

    private func document(zooms: [StudioProject.Zoom]) -> StudioDocument {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        return StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: Self.telemetry(), project: StudioProject(zooms: zooms), duration: 8,
            recordingSize: CGSize(width: 3200, height: 2000), folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
    }

    @Test func aimingAZoomKeepsItsSpotInsideTheRecordingAndMakesItAZoomByHand() {
        let zoom = StudioProject.Zoom(start: 1, end: 3, scale: 2, isAutomatic: true)
        let document = document(zooms: [zoom])
        defer { try? FileManager.default.removeItem(at: document.folder) }
        // Following the pointer, and before a movie is made, it looks at the middle.
        #expect(document.aim(of: zoom.id) == .init(x: 0.5, y: 0.5))
        document.setZoomTarget(zoom.id, .init(x: 1.4, y: -0.2))
        let aimed = document.project.zooms[0]
        #expect(aimed.target == .init(x: 1, y: 0) && !aimed.isAutomatic)
        #expect(document.aim(of: zoom.id) == .init(x: 1, y: 0))
        // Turned on again, the automatic zooms leave it where it is.
        document.setAutomaticZooms(false)
        document.setAutomaticZooms(true)
        #expect(document.project.zooms.contains { $0.id == zoom.id && $0.target == .init(x: 1, y: 0) })
        document.setZoomTarget(zoom.id, nil)
        #expect(document.project.zooms.first { $0.id == zoom.id }?.target == nil)
    }

    @Test func aimingByDragIsTakenBackAsOne() {
        let zoom = StudioProject.Zoom(start: 1, end: 3, scale: 2, isAutomatic: false)
        let document = document(zooms: [zoom])
        defer { try? FileManager.default.removeItem(at: document.folder) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }
        undo.beginUndoGrouping()
        document.beginContinuousChange()
        for step in 0..<10 { document.setZoomTarget(zoom.id, .init(x: 0.1 + Double(step) * 0.05, y: 0.5)) }
        document.endContinuousChange()
        undo.endUndoGrouping()
        #expect(document.project.zooms[0].target == .init(x: 0.55, y: 0.5))
        undo.undo()
        #expect(document.project.zooms[0].target == nil)
    }
}
