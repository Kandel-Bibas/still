# Verification

Automated tests exercise DSP behavior and routing policy. They do not prove that an
output device actually plays the expected audio. Complete the hardware checklist on
the target Mac before treating a build as production-ready.

## Automated gates

- `swift test`: gain smoothing, mute preservation, amplitude bounds, stereo/mono/planar
  mapping, unused-channel silence, physical-input offsets, malformed-buffer rejection,
  route choice, missing-device hold, and settings validation.
- `bash scripts/build.sh`: release build, app bundle creation, local code signing, and
  signature verification.
- `--diagnose`: enumerate real audio processes and output devices without tapping audio.
- `--render-previews`: inspect synthetic native light/dark/empty/missing-device views,
  a single app, and a crowded list that must scroll.
- `--discovery-probe`: checks registration after startup and idle/play/stop/resume
  using one continuously running engine and generated quiet audio.

## Hardware acceptance

1. Grant System Audio Recording permission. Run music in two apps at once. Set app A
   to 25% and B to 100%; confirm only A changes. Sweep A's slider and toggle mute without
   clicks. Unmuting restores its saved slider value.
2. Left-click the menu bar icon to open the panel and again to close it; confirm Escape,
   clicking outside the panel, and switching to another app also close it. Right-click the
   icon and confirm the menu (Enable Still / Still Settings… / Quit Still) works. Grow and
   shrink the app list (toggle "Show inactive apps", or let apps start/stop) and confirm the
   panel always resizes to match its content and stays anchored under the menu bar, including
   near screen edges. Confirm the icon dims when Still is switched off. Open Settings from
   the panel footer and from the right-click menu; close it and confirm the panel still
   opens normally afterward.
3. Assign A to headphones and B to speakers. Verify each device separately. Verify
   choosing System output follows changes to the Mac's default output for a managed app.
4. Disconnect A's headphones during playback. A stays silent, B keeps playing, and A's
   row says it is waiting. Reconnect the same device: A resumes there at the saved volume.
   The disappearance/reappearance must not create a growing number of Still devices.
5. Pause a configured app, disconnect headphones, resume. Confirm that its existing tap
   prevents playback through speakers. Also check app restarts separately: process
   discovery may allow initial audio before a new tap can be created; record that limitation.
6. Quit/relaunch the source app and Still. Verify saved routing, volume, mute, and favorites.
   Quitting/disabling Still deliberately restores original app playback.
7. Sleep and wake during playback; check output reconnection and mute preservation.
8. Deny/revoke capture access, retry, and verify failures are visible with a usable recovery.
   Check that a slider never claims a failed route is controlled successfully.
9. Test Bluetooth with microphone use, USB duplex headsets, 44.1/48 kHz sources and outputs,
   and HDMI if those devices are available. Confirm microphone audio never reaches output.
10. Test keyboard-only controls, VoiceOver labels, light/dark appearance, increased contrast,
    and reduced transparency. Native offscreen renders are not a substitute for these checks.
11. Measure release-build idle CPU for five minutes with panel closed and no managed output
    (target average <0.5% of one core). Record process memory, callback failures, and
    incremental `coreaudiod` CPU with 1/3/5 managed apps. Run at least a 30-minute playback
    soak and confirm no rising memory use, stalls, or repeated route recreation.
12. Idle grace: set an app to 50% and play it. Pause for about 3 seconds and resume;
    the first syllable or beat must be audible. Pause for more than 10 seconds, resume, and
    note whether the start is clipped (expected: a short gap, as before). Confirm that
    Bluetooth headphones drop out of their active state after about 10 seconds of silence.
13. Activity linger: with the panel open, stop an app and leave the panel alone. Its row
    must leave the active list about 15 seconds later without any other audio event.
14. Level meters: with the panel open, a controlled app shows a moving meter under its
    slider; muted and uncontrolled apps show none. Close the panel and confirm idle CPU
    returns to the step 11 baseline (metering stops).
15. Automation URLs: `open "still://volume?app=Music&value=30"`, `...mute?app=Music&state=on`,
    `...output?app=Music&device=system`, and a bad name, each from Terminal and once from
    a Shortcuts "Open URL" action, including once while Still is not running.

## Evidence recorded during initial build

- Xcode 27 / Swift 6.4, arm64, macOS 27.0.
- Suite: 26 tests passed (16 DSP, 10 routing/preferences).
- Initial read-only hardware discovery: MacBook Pro Speakers; no second output connected.
- Initial build idle interval: process CPU time increased from 0.68 to 0.81 seconds
  between elapsed times 3:33 and 9:37 (364 seconds): approximately 0.036% of one core.
  Mixer disabled, menu panel closed. RSS samples declined from 93,280 to 78,112 KiB
  (about 91 to 76 MiB). This measures the app process, not incremental coreaudiod cost.
- Computer Use UI automation unavailable because its OS permissions are not granted.
- Real generated-tone probe on MacBook Pro Speakers: 25% gain measured 0.25, mute peak
  0, 75% gain measured 0.75. A second simultaneous process remained at gain 0.60000002
  while the first was muted. No malformed-buffer faults. These measurements inspect
  PCM rendered to the device callback; they are not an acoustic measurement.
- Final probe also stopped and rebuilt an output route while preserving its tap:
  resumed gain measured exactly 0.5, with zero buffer faults. This exercises route
  lifecycle on the built-in output; it does not simulate a physical device disconnect.
- Native synthetic light/dark/onboarding/missing-device views rendered and visually
  inspected. Popover shrinks to its content and caps scrolling at 460pt.
- Real application listening, second-output routing, physical disconnection, sleep/wake,
  denial/revocation, accessibility interaction, and long soak remain unverified.

## 0.1.1 regression evidence

- The original engine failed the live discovery probe at `playbackStart`: an idle
  source was discovered, but starting audio in that same process produced no update.
  CoreAudio notified `IsRunning` while the `IsRunningOutput` value changed. Watching
  both notifications fixes this; output-specific state still determines activity.
- The packaged release passed all seven checks: late process registration, process
  exit, initially idle source, playback start, stop, resume, and second stop. No
  polling was added. The full 26-test suite also passed.
- The final bundled audio probe passed on MacBook Pro Speakers: gain ratios 0.25
  and 0.75, muted peak 0, independent stream 0.60000002, rebuilt route 0.5, and zero
  malformed-buffer faults.
- The old executable reported SDK 14.2 despite being built with SDK 27.0. The release
  script now explicitly records the actual build SDK while retaining macOS 14.2 as
  the minimum version, and rejects incorrect SDK metadata after linking.
- Native rendered fixtures show modern switches and slider thumbs. The panel is
  320pt wide, sizes naturally for short lists, and limits scrolling to 460pt for long
  lists. Its extra rectangular material layer was removed so MenuBarExtra owns the
  window background. Offscreen fixtures verify content layout, not menu-window chrome;
  live interaction remains unverified because Computer Use permission is unavailable.
