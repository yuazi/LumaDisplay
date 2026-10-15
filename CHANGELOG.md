# Changelog

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
