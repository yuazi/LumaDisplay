import XCTest
@testable import DisplayCore

final class PresetStorageTests: XCTestCase {
    private var preset: DisplayPreset {
        DisplayPreset(name: "Desk", displays: [SavedDisplay(uuid: "display-uuid", name: "Display",
            mode: ModeDescriptor(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 59.94),
            brightness: 0.7, dimming: 0.8, warmth: 0.2)])
    }

    func testMissingFileAndEmptyPresetList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presets.json")
        XCTAssertTrue(try PresetStorage.read(from: url).isEmpty)
        try PresetStorage.write([], to: url)
        XCTAssertTrue(try PresetStorage.read(from: url).isEmpty)
    }

    func testSystemManagedRefreshAndAppearanceBoundariesRemainValid() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for brightness: Double? in [nil, 0, 1] {
            var saved = preset
            saved.displays[0].mode.refreshRate = 0
            saved.displays[0].brightness = brightness
            saved.displays[0].dimming = 0.2
            saved.displays[0].warmth = 1
            try PresetStorage.write([saved], to: url)
            let display = try XCTUnwrap(try PresetStorage.read(from: url).first?.displays.first)
            XCTAssertEqual(display.brightness, brightness)
            XCTAssertEqual(display.dimming, 0.2)
            XCTAssertEqual(display.warmth, 1)
            XCTAssertEqual(display.mode.refreshLabel, "System managed")
            XCTAssertTrue(display.mode.matches(saved.displays[0].mode))
        }
    }

    func testInvalidPresetsAreRejectedWithoutChangingFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let valid = preset
        let validData = try JSONEncoder().encode([valid])
        let mutations: [(String, (inout DisplayPreset) -> Void)] = [
            ("missing displays", { $0.displays = [] }),
            ("missing display ID", { $0.displays[0].uuid = "" }),
            ("duplicate display ID", { $0.displays.append($0.displays[0]) }),
            ("zero width", { $0.displays[0].mode.width = 0 }),
            ("negative height", { $0.displays[0].mode.height = -1 }),
            ("zero pixel width", { $0.displays[0].mode.pixelWidth = 0 }),
            ("negative pixel height", { $0.displays[0].mode.pixelHeight = -1 }),
            ("negative refresh", { $0.displays[0].mode.refreshRate = -1 }),
            ("integer overflow", { $0.displays[0].mode.refreshRate = 1e100 }),
            ("scaled refresh overflow", { $0.displays[0].mode.refreshRate = 1e308 }),
            ("negative brightness", { $0.displays[0].brightness = -0.1 }),
            ("brightness above maximum", { $0.displays[0].brightness = 1.1 }),
            ("dimming below minimum", { $0.displays[0].dimming = 0.19 }),
            ("dimming above maximum", { $0.displays[0].dimming = 1.1 }),
            ("negative warmth", { $0.displays[0].warmth = -0.1 }),
            ("warmth above maximum", { $0.displays[0].warmth = 1.1 })
        ]
        var cases = mutations.map { name, mutate in
            var invalid = valid
            mutate(&invalid)
            return (name, [invalid])
        }
        cases.append(("duplicate preset ID", [valid, valid]))
        for (name, invalid) in cases {
            try validData.write(to: url)
            XCTAssertThrowsError(try PresetStorage.write(invalid, to: url), name)
            XCTAssertEqual(try Data(contentsOf: url), validData, name)
            let invalidData = try JSONEncoder().encode(invalid)
            try invalidData.write(to: url)
            XCTAssertThrowsError(try PresetStorage.read(from: url), name)
            XCTAssertEqual(try Data(contentsOf: url), invalidData, name)
        }
    }

    func testNonFiniteValuesCannotReplaceSavedPresets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try PresetStorage.write([preset], to: url)
        let original = try Data(contentsOf: url)
        for value in [Double.nan, .infinity, -.infinity] {
            let mutations: [(inout SavedDisplay) -> Void] = [
                { $0.brightness = value }, { $0.dimming = value },
                { $0.warmth = value }, { $0.mode.refreshRate = value }
            ]
            for mutate in mutations {
                var invalid = preset
                mutate(&invalid.displays[0])
                XCTAssertThrowsError(try PresetStorage.write([invalid], to: url))
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }
}
