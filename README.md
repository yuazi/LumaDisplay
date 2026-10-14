<p align="center">
  <img src="docs/icon.png" width="112" height="112" alt="LumaDisplay icon">
</p>

# LumaDisplay

Control your Mac's displays from a native dashboard or the menu bar. Adjust resolution, brightness and warmth, save your workspace as a preset, and use extra HDR brightness on compatible displays.

[Download the preview](https://github.com/yuazi/LumaDisplay/releases/tag/v1.0.0) · [Report an issue](https://github.com/yuazi/LumaDisplay/issues) · [Contribute](CONTRIBUTING.md)

## Features

- Connected-display discovery with resolution, refresh rate, pixel dimensions and HiDPI information.
- Resolution and refresh-rate selection from the modes macOS provides. Changes have a 15-second preview and automatic rollback.
- Hardware brightness on supported displays, plus software dimming down to 20%.
- Adjustable warmth for each display.
- Experimental HDR brightness boost with a 100% to 200% desktop-gain control, limited by the display's current HDR headroom.
- Local presets for resolution, brightness, dimming and warmth across connected displays.
- Menu-bar controls, display identification, and a shortcut to macOS Display Settings.

The app leaves display settings unchanged on launch. It has no analytics, network access, account requirement or background service.

## Install

The [v1.0.0 preview](https://github.com/yuazi/LumaDisplay/releases/tag/v1.0.0) includes an Apple silicon build for macOS 13 or later. Download the ZIP, extract it, and move `LumaDisplay.app` to Applications.

The download is ad-hoc signed and has not been notarized by Apple. If macOS blocks it, you can build the app from source using the steps below. Intel builds are not included in this release; the source targets the build machine's architecture, but Intel hardware has not been tested.

Closing the dashboard leaves LumaDisplay in the menu bar. Choose **Quit** to exit and remove its visual effects.

## Build from source

Install Xcode or Apple's Command Line Tools with Swift 5.9 or later, then run:

```sh
git clone https://github.com/yuazi/LumaDisplay.git
cd LumaDisplay
./Scripts/build-app.sh
open dist/LumaDisplay.app
```

You can also open `Package.swift` in Xcode. The project has no external Swift package dependencies. The build script compiles the app, generates its icon, includes the license notices, and signs the local bundle.

## HDR extra brightness

On a supported display, turn on **HDR boost**, then adjust **Desktop gain**. LumaDisplay uses a Metal overlay to amplify desktop content within the available extended dynamic range (EDR). It adapts the applied gain as that headroom changes.

HDR boost starts off and turns off when the app quits or the Mac or display sleeps. Presets do not enable it. External HDR monitors must already have HDR enabled in macOS Display Settings; an SDR-only monitor cannot gain HDR capability through the app.

The percentages describe software gain, not measured nits. Boost can affect HDR highlights and increase power use. Turn it off for color-critical work and accurate HDR viewing. The feature is experimental; the display and macOS still determine the available output.

## Presets and recovery

Presets are stored in `~/Library/Application Support/LumaDisplay/presets.json` and match displays by stable UUID. Applying a preset reports missing displays or unavailable modes before making changes. When a preset changes resolution, brightness and warmth apply after you choose **Keep changes**.

Unconfirmed display modes are scoped to the app, so macOS restores session settings when the process exits. The rollback timer runs during menu interactions. A failed rollback retains its original settings and offers a retry. Confirmed modes last for the current login session.

Use **Displays → Reset HDR, Dimming & Warmth** or **⌘⇧0** to remove all visual effects. Hardware brightness remains at its current setting.

## Compatibility and limits

The app has been tested on an Apple M1 Pro Mac with a built-in Retina display. Desktop brightening was visually confirmed on that panel. Physical luminance has not been measured. External monitors, multiple-display hot-plug, and the full range of supported macOS versions still need testing.

Hardware brightness uses an optional private DisplayServices API whose availability can change with macOS. Software dimming and warmth use overlays, which can behave differently on secure system surfaces, in full-screen apps, or alongside other display utilities.

This release does not implement DDC/CI, virtual displays, custom modes, EDID overrides, direct hardware XDR upscaling, display arrangement, rotation, mirroring controls, streaming or picture-in-picture. Use macOS Display Settings for mirrored-display mode changes.

## Development checks

```sh
swift test
dist/LumaDisplay.app/Contents/MacOS/LumaDisplay --diagnose
dist/LumaDisplay.app/Contents/MacOS/LumaDisplay --diagnose-hdr
```

Both diagnostic commands read display information and exit. The seven tests cover rollback, confirmation and failure recovery, HDR gain limits, and preset persistence. XCTest requires a full Xcode installation on systems whose Command Line Tools do not include it. You can select an installed Xcode for a single invocation with `DEVELOPER_DIR`.

For a rendering smoke test, `--verify-hdr` briefly applies 110% gain for three seconds, reports completed Metal frames, then disables boost and exits. It changes the display during the test.

## License and credits

LumaDisplay is licensed under [GNU GPL version 3](LICENSE). Its HDR rendering technique is adapted from [BrightIntosh](https://github.com/niklasr22/BrightIntosh) by Niklas Rousset and contributors. See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution and source references.
