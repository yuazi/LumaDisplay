# Contributing

Bug reports and pull requests are welcome. For display issues, include your Mac model, macOS version, display model, connection type, and steps to reproduce the problem. Mention whether HDR is enabled and whether another display utility is running. Review diagnostic output before attaching it; display identifiers are usually unnecessary for a public report.

## Build and test

```sh
swift test
./Scripts/build-app.sh
open dist/LumaDisplay.app
```

Use a full Xcode toolchain if your Command Line Tools installation lacks XCTest. Keep display changes reversible, surface hardware errors, and test recovery as well as successful application. Do not enable HDR boost automatically on startup or when applying a preset.

Describe the behavior your change fixes and the checks you ran. Distinguish software tests from observations on a physical display; screenshots and EDR headroom do not measure panel luminance.

Contributions are distributed under the project's GPL-3.0 license. Preserve third-party notices and identify any additional code or assets you introduce.
