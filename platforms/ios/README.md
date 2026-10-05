# DisplayBridge for iPhone and iPad

Turns an iPhone or iPad into a second monitor for a Mac running DisplayBridge. Sink
only, like the Android app: it receives, decodes and shows the display, and sends
touches back as pointer input.

## Build

Needs Xcode 15 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and Rust.

```bash
make ios                                   # from the repository root
open platforms/ios/DisplayBridge.xcodeproj
```

In Xcode pick your team under Signing & Capabilities, then run on a device or a
simulator. Run `make ios` again after changing anything under `core/`.

## Use

Start the source on the Mac. The app lists it under "Found on this network"; tap it,
enter the pairing code the Mac shows, and connect. One finger taps and drags, two
fingers scroll, a two-finger tap is a right click; Apple Pencil pressure is passed on.

## Limits

- Network only. USB would need Apple's MFi accessory program.
- Landscape only.
- HEVC only.

## Status

Written without an iOS SDK at hand: the Rust core is built for both iOS targets, the
shared Swift code and the app's SwiftUI are compiled on macOS, and the touch gestures
and discovery are tested there. The UIKit-only pieces (`DisplaySinkView+iOS.swift` in
the shared package, the `#if os(iOS)` branches in `App/`) and this project spec have
not been through Xcode yet.
