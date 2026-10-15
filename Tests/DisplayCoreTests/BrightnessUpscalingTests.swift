import XCTest
@testable import DisplayCore

final class BrightnessUpscalingTests: XCTestCase {
    enum Failure: Error { case hardware, storage }

    func testDriverUnitsAndPhysicalCeiling() throws {
        XCTAssertEqual(try BrightnessScale.fixedPoint(nits: 600), 39_321_600)
        XCTAssertEqual(try BrightnessScale.fixedPoint(nits: 600.5), 39_354_368)
        XCTAssertEqual(try BrightnessScale.directTarget(gain: 2, standardNits: 600, ceilingNits: 750), 750)
        XCTAssertEqual(try BrightnessScale.directTarget(gain: 5, standardNits: 600, ceilingNits: 1600), 1200)
        XCTAssertThrowsError(try BrightnessScale.fixedPoint(nits: .nan))
        XCTAssertThrowsError(try BrightnessScale.fixedPoint(nits: .infinity))
        XCTAssertThrowsError(try BrightnessScale.fixedPoint(nits: -1))
        XCTAssertThrowsError(try BrightnessScale.directTarget(gain: 1.2, standardNits: 1600, ceilingNits: 600))
        XCTAssertEqual(BrightnessScale.bounded(.nan), 1)
        XCTAssertEqual(BrightnessScale.bounded(3), 2)
    }

    func testCheckpointFailurePreventsHardwareChanges() {
        var changed = false
        let change = ReversibleChange<Int>(checkpoint: { _ in throw Failure.storage })
        XCTAssertThrowsError(try change.begin(snapshot: 1, apply: { changed = true }, restore: { _ in changed = false }))
        XCTAssertFalse(changed)
        XCTAssertNil(change.original)
    }

    func testPartialWriteFailureRestoresEveryOriginalSetting() {
        var device = ["cap": 600, "level": 300, "preset": 0]
        let original = device
        var checkpoint: [String: Int]?
        let change = ReversibleChange<[String: Int]>(checkpoint: { checkpoint = $0 })
        XCTAssertThrowsError(try change.begin(snapshot: original, apply: {
            XCTAssertEqual(checkpoint, original)
            device["preset"] = 1
            device["cap"] = 1200
            throw Failure.hardware
        }, restore: { device = $0 }))
        XCTAssertEqual(device, original)
        XCTAssertNil(checkpoint)
        XCTAssertNil(change.original)
    }

    func testFailedRestorationKeepsSnapshotForRetry() throws {
        var device = 300
        var saved: Int?
        let change = ReversibleChange<Int>(checkpoint: { saved = $0 })
        XCTAssertThrowsError(try change.begin(snapshot: device, apply: {
            device = 900
            throw Failure.hardware
        }, restore: { _ in throw Failure.hardware }))
        XCTAssertEqual(saved, 300)
        XCTAssertEqual(change.original, 300)
        XCTAssertEqual(device, 900)
        try change.restore { device = $0 }
        XCTAssertEqual(device, 300)
        XCTAssertNil(saved)
        XCTAssertNil(change.original)
    }

    func testGainUpdateCannotReplaceOriginalSnapshot() throws {
        var device = 300
        let change = ReversibleChange<Int>(checkpoint: { _ in })
        try change.begin(snapshot: 300, apply: { device = 600 }, restore: { device = $0 })
        try change.update(apply: { device = 900 }, restore: { device = $0 })
        XCTAssertThrowsError(try change.begin(snapshot: 900, apply: { device = 1200 }, restore: { device = $0 }))
        try change.restore { device = $0 }
        XCTAssertEqual(device, 300)
    }

    func testRecoveredCheckpointRestoresBeforeRemoval() throws {
        var device = 900
        var saved: Int? = 300
        let change = ReversibleChange(recovered: saved, checkpoint: { value in
            XCTAssertEqual(device, 300)
            saved = value
        })
        try change.restore { device = $0 }
        XCTAssertEqual(device, 300)
        XCTAssertNil(saved)
    }

    func testCheckpointRemovalFailureRetainsIdempotentRecovery() throws {
        var device = 300
        var rejectRemoval = true
        let change = ReversibleChange<Int>(checkpoint: { value in
            if value == nil && rejectRemoval { throw Failure.storage }
        })
        try change.begin(snapshot: 300, apply: { device = 900 }, restore: { device = $0 })
        XCTAssertThrowsError(try change.restore { device = $0 })
        XCTAssertEqual(device, 300)
        XCTAssertEqual(change.original, 300)
        rejectRemoval = false
        try change.restore { device = $0 }
        XCTAssertNil(change.original)
    }
}
