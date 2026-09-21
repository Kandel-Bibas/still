# Proposed agent notes

These are proposed contents, not installed agent instructions.

## Root AGENTS.md

```markdown
# Still — agent notes

- `bash scripts/build.sh` creates `dist/Still.app`, including its audio-capture usage
  description and local signature. Running the bare SwiftPM executable is not the
  supported route for testing macOS privacy prompts.
- `swift test` runs DSP and routing/preferences tests. Hardware routing needs the
  separate checks in `docs/verification.md`.
- The app's `--audio-probe` command plays generated test tones and writes a JSON report;
  `--render-previews` renders synthetic native views without screen capture.
- `dist/` is generated. Local ad-hoc signing is not a distributable notarized release.
- The release script passes the actual SDK version to the linker. Plain `swift build`
  can record the deployment target as the SDK and enable older macOS control styling.
- `--discovery-probe` checks live CoreAudio playback transitions with generated audio;
  process activity notifications must watch both IsRunning and IsRunningOutput.
```

## Root CLAUDE.md

```text
@AGENTS.md
```
