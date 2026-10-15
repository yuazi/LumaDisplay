# Changelog

## 1.1.1 preview

- Added an install command that moves the build into Applications, registers it with macOS, and archives the previous installation to avoid duplicate app bundles.
- The dashboard and About popover now show the installed version instead of a hard-coded 1.0 label.
- Reopening the app from a launcher restores its dashboard even when the menu-bar panel is visible.

## 1.1.0 preview

- Added a unified brightness slider with upscaling above 100%.
- Added a choice of HDR overlay and experimental Direct XDR upscaling on supported built-in displays.
- Direct mode preserves display properties, preset, automatic brightness and hardware brightness, with transactional rollback and recovery after an interrupted session.
- Added periodic recovery, fullscreen activity pulses and a bounded direct-mode smoke test.
- Added seven tests for brightness units, physical limits, checkpoint failures and restoration retries.

## 1.0.1 preview

- Fixed HDR boost disappearing when another app enters a full-screen Space, including Netflix in Comet.
- HDR, dimming and warmth now use panels that follow full-screen apps without taking keyboard or mouse focus.
- Reposition existing effects when switching Spaces or applications. Temporary Space transitions no longer count as missing HDR rendering surfaces.
- Added overlay visibility diagnostics and a bounded full-screen smoke test.

## 1.0.0 preview

First public release of LumaDisplay.

- Native SwiftUI dashboard and menu-bar controls.
- Display discovery, HiDPI modes, resolution and refresh-rate selection.
- Display-mode previews with automatic rollback and failure recovery.
- Hardware brightness where supported, software dimming, and per-display warmth.
- Experimental Metal HDR boost from 100% to 200%, bounded by available headroom.
- Local presets tied to display UUIDs.

The first downloadable build targets Apple silicon. HDR brightness has been visually confirmed on a built-in display; external-display compatibility still needs testing.
