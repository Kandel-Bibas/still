# Still

A native macOS menu bar mixer with per-app volume, mute, and output routing.
SwiftUI and Core Audio process taps. No third-party dependencies, installed audio driver,
privileged helper, recording, or network service.

## Build and run

Requires macOS 14.2+ and Xcode 16+ (Swift 6 compiler). This checkout is being developed
with Xcode 27 on Apple Silicon. Older OS and Intel hardware still require runtime testing.

```sh
swift test
bash scripts/build.sh
open dist/Still.app
```

The build produces a locally ad-hoc-signed `dist/Still.app`. It is suitable for local
testing, not a notarized distribution. To distribute it, use your own Developer ID
signing and notarization. Rebuilding an ad-hoc-signed app may require macOS to grant
audio capture permission again.

Open the sliders icon in the menu bar, enable Still, and change an app's volume or
output. The first managed route requests macOS **System Audio Recording** permission.
If denied, allow Still in System Settings → Privacy & Security → Screen & System Audio
Recording, then retry the route (or reopen Still if macOS asks).

## Controls

- Left-click the menu bar icon to open or close the panel. Escape, clicking outside
  it, or switching apps closes it.
- Right-click the icon for a menu: Enable Still, Still Settings…, and Quit Still.
- The icon dims when the mixer is off. Still makes its menu bar item visible at every
  launch, so a hidden item cannot persist across restarts. macOS still hides items when
  the menu bar runs out of room, which a Mac with a notch does at a smaller item count.
- The app list scrolls once it outgrows the space below the menu bar; the cap
  adapts to the screen height.
- Active audio apps appear automatically; pin favorites to retain them while inactive.
- Each app has a 0–100% amplitude slider, a separate mute button, and an output picker.
- System output follows the Mac's default output for managed routes. Untouched apps
  at 100% use their own original audio path, including any device selected inside that app.
- If an explicitly selected device disappears, Still retains a muting tap and waits
  for that device. It never intentionally falls back to speakers. Choose another output
  to resume elsewhere.
- Switching the mixer off or quitting releases Still's control. Apps return to their
  own original volume and output; that can make a previously muted app audible.
- Settings opens from the panel footer or the right-click menu (⌘, still works while
  the panel is focused). It includes launch at login; move the app to a stable
  location before enabling it.
- Preferences live in `~/Library/Application Support/Still/preferences.json`.

## Audio architecture

An event-driven control queue discovers Core Audio processes/devices and manages one
private process tap + private aggregate output per controlled app. Original app output
is suppressed while a tap exists, including while an output is absent or being rebuilt.
Known configured processes get their taps before playback; output I/O starts only when
they become active. New processes still require discovery, so initial audio at app launch
cannot be guaranteed suppressed on every supported OS.

A C++ callback maps stereo Float32 PCM to a supported output with a 5ms gain ramp.
Its callback performs no allocation, locks, logging, Swift/Objective-C calls, or file I/O.
It explicitly disables physical input streams and validates buffer geometry to avoid
playing microphone input. Core Audio aggregate tap drift compensation handles clock
differences. Unsupported formats fail visibly rather than attempting unsafe playback.

Device/process notifications drive discovery. A one-second health check exists only
while routes render; there are no persistent meters or UI animation timers. Unmodified
apps bypass audio processing. Settings writes are debounced and atomic.

## Current boundaries

- Supports a stereo mixed tap and a single Float32 output stream, including mono
  downmix or the first two channels of a multichannel stream. Multiple output streams,
  encoded audio, specialized channel maps, and exclusive-device applications are not supported.
- Nested browser/Electron helpers are grouped with their enclosing app. Shared system
  helpers whose owner cannot be established remain separate named sources; browser-tab
  routing is not implemented.
- Abrupt Bluetooth changes and sleep/wake can produce a brief gap. Failed routes remain
  muted with a retry action while their taps can be retained. If tap creation itself fails,
  Still cannot suppress the original audio and reports the failure.
- No boost, EQ, recording, auto-ducking, solo, global hotkeys, or Shortcuts integration.

## Development diagnostics

```sh
# Read-only inventory; prints local device identifiers and running audio apps.
dist/Still.app/Contents/MacOS/Still --diagnose

# Render synthetic native UI fixtures. Doesn't capture the screen or start audio routes.
dist/Still.app/Contents/MacOS/Still --render-previews dist/previews

# Live discovery regression: new processes and idle/play/stop/resume in one engine.
# Plays generated quiet audio without creating taps or changing saved preferences.
dist/Still.app/Contents/MacOS/Still --discovery-probe "$PWD/dist/discovery-probe.json"

# Live probe: plays two quiet generated tones, checks independent gain/mute and route
# rebuilding, then exits. Use an absolute report path; may request audio permission.
open -n dist/Still.app --args --audio-probe "$PWD/dist/audio-probe.json"
```

See [the hardware verification checklist](docs/verification.md) for release checks.
