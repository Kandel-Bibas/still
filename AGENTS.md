# Still — agent notes

macOS menu bar per-app volume mixer. SwiftPM package, no third-party dependencies:
a SwiftUI panel hosted by AppKit, Core Audio process taps, one C++ render callback.

## Commands
- Build the app: `bash scripts/build.sh` → `dist/Still.app`. Use this rather than a
  bare `swift build`. The script pins the linker's SDK/deployment-target pair, without
  which AppKit and SwiftUI fall back to an older control appearance, and it adds the
  Info.plist and ad-hoc signature the audio-capture prompt needs.
- Test (all): `swift test`  ·  Test (single): `swift test --filter PanelPlacementTests`
- Look at the UI without a screen: `dist/Still.app/Contents/MacOS/Still --render-previews <dir>`
  renders the real panel to PNGs in every state. This is the UI verification loop —
  read the PNGs rather than asking for a screenshot.
- Read-only hardware inventory: `--diagnose`. Live audio probes are `--audio-probe`
  and `--discovery-probe`; both play generated tones. See `docs/verification.md`.

## Done means
- `swift test` passes and `bash scripts/build.sh` completes.
- Any UI change has been viewed via `--render-previews`, light and dark.
- Anything touching routing or devices needs the hardware checks in
  `docs/verification.md`. They cannot be run headlessly; say so rather than claiming
  the change is verified.

## Where things live
- Pure, testable logic belongs in `Sources/MixerCore`. The test target imports only
  `MixerCore` and `AudioDSP`; `Sources/Still` is the executable and has no unit tests,
  so logic worth testing has to be moved out of it first.
- The realtime path is `Sources/AudioDSP/AudioDSP.cpp`. Its callback must stay free of
  allocation, locks, logging, and Swift/Objective-C calls.

## Boundaries
- Ask first: the `preferences.json` schema (`version` is a hard compatibility gate,
  not a migration mechanism), anything inside the render callback, new dependencies.
- Never: commit `dist/` or `.build/`; weaken the tap's `.muted` behaviour to make a
  route work — it is what suppresses the app's original output.

## Gotchas
- Do not reintroduce SwiftUI `MenuBarExtra` or the `Settings` scene.
  `MenuBarExtra(.window)` does not resize its window when SwiftUI content changes, so
  the panel showed dead space or clipped its own header and footer. The status item,
  panel, and settings window are AppKit on purpose.
- Position the panel against the display holding the menu bar item, never
  `NSWindow.screen` — that reports where the panel last opened and drags it onto the
  wrong monitor. `PanelPlacement` is pure so this stays covered by tests.
- Menu bar icon dimensions must both be even. An odd height centres on a half pixel in
  a 24pt menu bar and looks blurred on a non-Retina display, while looking fine on a
  Retina one.
- `screencapture -R` only covers the main display. Use `-D <n>` for another one, which
  matters when checking the panel on a second monitor.
- Process activity must watch both `kAudioProcessPropertyIsRunning` and
  `kAudioProcessPropertyIsRunningOutput`. The first alone misses playback start.

## Deeper docs (read when relevant)
- Release checks → `docs/verification.md`
- How the whole app fits together → `docs/still-report.html`
