import XCTest
@testable import DisplayCore

final class DisplayCoreTests: XCTestCase {
    enum Failure: Error { case hardware }
    func testHDRGainTracksAvailableHeadroomWithoutExceedingTwoTimes() {
        XCTAssertEqual(HDRGain.effective(requested: 2, currentHeadroom: 3.2), 2)
        XCTAssertEqual(HDRGain.effective(requested: 2, currentHeadroom: 1.4), 1.4)
        XCTAssertEqual(HDRGain.effective(requested: 1.5, currentHeadroom: 1), 1)
        XCTAssertEqual(HDRGain.effective(requested: 16, currentHeadroom: 16), 2)
        XCTAssertEqual(HDRGain.effective(requested: .nan, currentHeadroom: 3), 1)
        XCTAssertEqual(HDRGain.effective(requested: 1.5, currentHeadroom: .infinity), 1)
    }
    func testTimeoutRestoresAllOriginalDisplays() throws {
        var hardware = [1: "retina", 2: "4k"]
        let original = hardware
        let preview = ModePreview<[Int: String]> { hardware = $0 }
        let start = Date(timeIntervalSince1970: 100)
        try preview.begin(original: original, proposed: [1: "1080p", 2: "1440p"], now: start)
        XCTAssertFalse(preview.tick(now: start.addingTimeInterval(14)))
        XCTAssertEqual(hardware[1], "1080p")
        XCTAssertTrue(preview.tick(now: start.addingTimeInterval(16)))
        XCTAssertEqual(hardware, original)
        XCTAssertFalse(preview.isPending)
    }
    func testConfirmationDoesNotUndoNewMode() throws {
        var hardware = "old"
        let preview = ModePreview<String> { hardware = $0 }
        let start = Date()
        try preview.begin(original: hardware, proposed: "new", now: start)
        try preview.confirm()
        XCTAssertFalse(preview.tick(now: start.addingTimeInterval(30)))
        XCTAssertEqual(hardware, "new")
    }
    func testFailedRollbackPreservesRecoverySnapshot() throws {
        var hardware = "old"
        var rejectRollback = true
        let preview = ModePreview<String> {
            if $0 == "old" && rejectRollback { throw Failure.hardware }
            hardware = $0
        }
        try preview.begin(original: hardware, proposed: "new")
        XCTAssertFalse(preview.revert())
        XCTAssertEqual(preview.original, "old")
        try preview.confirm()
        XCTAssertTrue(preview.isPending)
        rejectRollback = false
        XCTAssertTrue(preview.revert())
        XCTAssertEqual(hardware, "old")
    }
    func testFailedApplyDoesNotStartPreviewAndNestedPreviewIsRejected() throws {
        let rejected = ModePreview<String> { _ in throw Failure.hardware }
        XCTAssertThrowsError(try rejected.begin(original: "a", proposed: "b"))
        XCTAssertFalse(rejected.isPending)
        let preview = ModePreview<String> { _ in }
        try preview.begin(original: "a", proposed: "b")
        XCTAssertThrowsError(try preview.begin(original: "b", proposed: "c"))
        XCTAssertEqual(preview.original, "a")
    }
    func testFailedKeepRetainsTimedRollback() throws {
        var hardware = "old"
        let preview = ModePreview<String> { hardware = $0 }
        let start = Date()
        try preview.begin(original: hardware, proposed: "new", now: start)
        XCTAssertThrowsError(try preview.confirm { throw Failure.hardware })
        XCTAssertTrue(preview.isPending)
        XCTAssertTrue(preview.tick(now: start.addingTimeInterval(16)))
        XCTAssertEqual(hardware, "old")
    }
    func testPresetRoundTripRetainsStableDisplayIdentityAndFractionalRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presets.json")
        let mode = ModeDescriptor(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 59.94)
        let preset = DisplayPreset(name: "Editing", displays: [.init(uuid: "display-uuid", name: "Studio", mode: mode, brightness: 0.7, dimming: 0.8, warmth: 0.2)])
        try PresetStorage.write([preset], to: url)
        let loaded = try XCTUnwrap(try PresetStorage.read(from: url).first)
        XCTAssertEqual(loaded.id, preset.id)
        XCTAssertEqual(loaded.displays.first?.uuid, "display-uuid")
        XCTAssertEqual(loaded.displays.first?.mode.refreshRate, 59.94)
        XCTAssertTrue(mode.isHiDPI)
        XCTAssertEqual(mode.refreshLabel, "59.94 Hz")
        XCTAssertFalse(mode.matches(.init(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 59.94)))
    }
}
