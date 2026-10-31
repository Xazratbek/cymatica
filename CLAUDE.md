# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Cymatica is a native macOS menu bar app (Swift Package, Swift + Metal + a little SwiftUI). It shows an "always-on display": golden sand on a vibrating plate that forms Chladni figures from whatever the Mac is playing, or draws the time (clock mode). The UI is in Uzbek, Russian and English; Uzbek is the default. The README is English with a short Uzbek section; `idea.txt` (Uzbek) holds ideas for future modes.

## Commands

```bash
./build_app.sh                      # swift build -c release, assembles build/Cymatica.app, ad-hoc signs it
open build/Cymatica.app             # run it (menu bar icon); use `open`, see "Audio permission" below
swift build -c release              # compile only (the binary is .build/release/Cymatica)
```

There is no test target. Verification is done with the headless modes of the binary, then by looking at the output:

```bash
B=.build/release/Cymatica
$B --snapshot out.png --mode 2,4 --frames 360          # offscreen render: --mode tier,pitchClass
$B --snapshot out.png --circle --mode 1,4
$B --snapshot out.png --mode 1,9 --then 1,4 --after 25 # switch figure after N frames, render the jump
$B --snapshot out.png --clock digital|analog|rings --time 10:08:37 [--after 40] [--no-seconds]
$B --snapshot out.png --clock rings --place 4 --plate-size 0.6   # placement (Placement rawValue) and size
$B --snapshot out.png --grains 300000 --size 3024x1964 --frames 600   # prints ms/frame, used as the perf benchmark
$B --analyze song.wav                                   # analyzer decisions per second: dB, drive, note, tier, beats, mode switches
open --stdout /tmp/tap.txt build/Cymatica.app --args --tap-test 8   # checks system audio capture (peaks per 0.5 s)
open build/Cymatica.app --args --demo|--show|--settings|--settings-tab appearance|--file song.wav
```

`--stay` keeps the plate up while the user works (for screen captures). `--dump-frame path.png` saves a live frame offscreen. To capture the real window, launch with `open --stderr log ... --args --show --stay`, read the `window N` number from the `Cymatica: showing on ...` log line, and run `screencapture -x -o -l N out.png`. Snapshots are SDR. On the XDR panel EDR highlights are brighter than in the PNG.

Generate test tones with ffmpeg (`-f lavfi -i "sine=frequency=440:duration=6"`) and feed them to `--analyze`.

## Architecture

Data flows one way, once per frame on the main thread (MTKView delegate):

`SystemAudioTap` (Core Audio process tap, IO thread) → `AudioRing` (lock-free SPSC ring) → `MusicAnalyzer` → `Visualizer` → `PlateField` / `ClockFace` → `Renderer` (Metal) → MTKView inside the `AODController` window.

- **Audio.** The tap is a global stereo process tap in a *tap-only* private aggregate device. Do not add the output device as a sub-device: that opens its microphone and drops AirPods to call quality. The IO block must not allocate or lock; it only writes into the ring. If no callbacks arrive (for example, permission is still pending), a watchdog rebuilds the tap with backoff. When the default output device changes, the tap is rebuilt.
- **Analysis (`MusicAnalyzer`).** Chroma is computed from peak-picked 16384-point FFT bins. The dominant pitch class switches only with hysteresis and a minimum 2.2 s hold, because sand needs 1–2 s to settle into a figure. The complexity tier (0–2) comes from section loudness relative to a ~60 s mean. Onsets and beats come from spectral flux, major/minor from Krumhansl key profiles. The visualizer runs the analyzer at most at 60 Hz and the long FFT at 30 Hz. A stalled ring must read as silence.
- **Plate physics.** `PlateField` maps (tier, pitch class) to an eigenmode: square plates use the Ritz formula `cos(nπx)cos(mπy) ± cos(mπx)cos(nπy)`; circle plates use Bessel `J_n(k r) cos nθ`, with radial profiles written into a shared buffer. Mode changes crossfade up to 4 slots. In `simulateGrains`, a grain hops only when `drive · gain · amplitude` exceeds a threshold ("plate acceleration > g"), so sand collects on nodal lines by itself. Keep this mechanism; gradient-descent shortcuts look synthetic.
- **Clock mode.** `ClockFace` turns the time into capsule strokes (a custom stroke font, analog hands, rings). When the strokes change, `bakeClockField` writes a 1024² distance/direction field, and grains sample it, so the clock costs the same as music mode. In clock mode, hops are steered toward the nearest stroke, and a small "sprinkle" redistributes sand onto strokes that appear in empty space. `clockMix` crossfades between plate modes and the clock (Mixed mode switches to the clock about 2.5 s into silence). The camera turns to a front-facing "reading pose" as `clockMix` rises.
- **Rendering.** Grain state lives only in a private GPU buffer. Grains are additive point sprites in an rgba16Float scene, followed by a 4-level dual-filter bloom and a composite into an EDR CAMetalLayer (extended linear Display P3). The composite's hue-preserving shoulder keeps dense gold from going white. The black floor keeps empty space at exactly 0 so mini-LED zones stay off. Do not add ambient haze.
- **Shaders** are a Swift string (`Shaders.swift`) compiled at launch with `makeLibrary(source:)`, so no offline Metal toolchain is needed. `SimUniforms`, `DrawUniforms`, `CompositeUniforms` and `ClockStroke` are mirrored by hand in `Renderer.swift` / `ClockFace.swift`: field order, types and padding must stay identical on both sides.
- **Always-on display (`AODController`).** A borderless window at `.screenSaver` level. Idle time is polled with `CGEventSource.secondsSinceLastEventType`, so no Accessibility permission is needed. The window fades in when music plays (or always, with "also without music") and the Mac has been idle long enough. Input closes it (keyboard optional). It holds a display-sleep assertion only while shown. The "stay hidden during video" check counts display-sleep assertions only from processes that are real apps (`NSRunningApplication`), so `caffeinate` and daemons do not block it. The MTKView is created outside a window, so `place(on:)` must set `layer.contentsScale`: with 0 the view renders but nothing appears on screen.

## Settings and UI

- `Settings.swift` wraps UserDefaults. `SettingsView.swift` binds to the **same keys** with `@AppStorage`, and the defaults must match on both sides. Changes reach the renderer through `UserDefaults.didChangeNotification` → `AppDelegate.applySettings()`. Values read live (auto mode, idle time, captions, screen) need no wiring.
- The settings window is an `NSWindowController` with `.fullSizeContentView` (needed for the Liquid Glass chrome). The menu bar app switches to `.regular` activation while it is open (`AppActivationPolicy`).
- In this window, `.menu`-style SwiftUI Pickers did not persist their selection. Use segmented pickers, radio groups, sliders (snap through `rounded(_:to:)` rather than `step:`, which draws tick marks) or custom controls like `PlacementGrid`.
- Localization is `tr(uz, ru, en)` at each call site (`Localization.swift`). Views refresh on language change through `@AppStorage("language")` and `.id(language)`. The permission prompt text lives in `Resources/*.lproj/InfoPlist.strings`. New user-facing strings need all three languages.

## Audio permission and signing

System audio capture needs the bundle's `NSAudioCaptureUsageDescription`, so run the app through `open` (a bare binary from a terminal attributes the permission to the terminal). The bundle is ad-hoc signed; after a rebuild macOS may ask for System Audio Recording again, or silently deliver no audio until it is re-allowed.

## Performance baseline

On an M2 Pro, 300k grains at 3024×1964 take about 1 ms/frame in every mode (from `--snapshot ... --grains 300000 --size 3024x1964 --frames 600`). While the plate is hidden, rendering is paused and the app idles at about 0.1% CPU. Re-measure with the same command after touching the simulation or render passes.
