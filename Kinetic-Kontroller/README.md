# Kinetic Kontroller

A native-feeling macOS app for controlling the LEDs on an **Akai APC mini mk2**. Pick a
scene from the library and the pads change right away. Only one effect ever drives the
LEDs at a time, and **BLACKOUT** (or the `0` key) turns everything off.

- Scene library with favorites, live previews and keyboard shortcuts
- On-screen APC that mirrors the physical pads, including hardware pulse/blink
- Global **Speed** and **Brightness** (the APC's seven official brightness levels)
- Per-scene settings (colors via the macOS color panel, text, modes), applied live
- Auto-detects the `APC mini mk2 Control` port and reconnects after unplug/replug
- APC hardware: the 8 green **scene buttons** (right column, top = 1) start favorites 1–8, and
  **Shift + scene** blacks out. Out of the box, number key N, favorite N and scene button N are the
  same scene, with **Kinetic Sweep in #1**
- Diagnostics panel in the app, so you never need Terminal
- LEDs stay off at launch unless you turn on "Start last scene at launch"

## Kinetic Sweep (interactive)

A soft band of retro-rainbow light sweeps across the pads. It bounces by default,
easing into each edge and turning around smoothly, and can leave fading trails.
Every pad you press on the APC, or click on screen, starts its own reaction from
that pad:

| Reaction | Look |
|---|---|
| Ripple | origin flashes, then a ring expands 2–4 pads |
| Horizontal / Vertical Pulse | energy races along the row / column to both edges |
| Bloom | soft glow around the pad that melts back into the sweep |
| Spark | instant pale flash with a quick burst into the neighbouring pads, built for fast playing |

- **Overlap.** Reactions overlap: each press is its own event, and expired ones are removed automatically.
- **Hold.** A held pad stays bright and breathes gently; on release it fades back into the sweep.
- **Controls.** SWEEP: Speed, Intensity, Trails, Direction (Bounce, Left → Right, Right → Left, Randomized).
  TOUCH: Reaction, Touch Intensity, Touch Decay (0.15–2 s), Velocity, Color Wake.
- **Presets.** OXI, RETRO, NEON, AMBIENT, PERFORMANCE and ZEN. **RESET** restores the defaults.
- **Velocity** is used subtly if the pads send it. APC mini mk2 pads usually send a fixed 127,
  and that's handled gracefully. Diagnostics shows which one your unit does.
- **Color Wake.** Touches briefly tint the sweep around them, and the tint drifts away from the pad.
- **Best look.** Use **LED OUTPUT → RGB** for the smoothest fades. Palette mode works too; see below.

## Install

```bash
cd Kinetic-Kontroller
./build_app.sh            # builds dist/Kinetic Kontroller.app, then offers to copy it to /Applications
```

Or drag `dist/Kinetic Kontroller.app` into Applications yourself. The app bundles its own
Python and Qt. It does not need Homebrew, this virtual environment, or anything on your `$PATH`.

The build targets your Mac's architecture: **arm64** on Apple Silicon, **x86_64** on Intel.
The script prints which one it built. A universal build needs a universal2 Python
(python.org installer): `TARGET_ARCH=universal2 PYTHON=/usr/local/bin/python3.12 ./build_app.sh`.

A prebuilt arm64 `.app` is also attached to every GitHub Actions run of the
**Kinetic Kontroller** workflow, as the artifact `Kinetic-Kontroller-macOS-arm64`. It is
ad-hoc signed, so macOS quarantines a downloaded copy. Either right-click → **Open** the first
time, or run `xattr -dr com.apple.quarantine "/Applications/Kinetic Kontroller.app"`.
A copy you build yourself doesn't have this problem.

## Development

```bash
./run_dev.sh              # creates .venv on first run, then launches from source
./run_dev.sh --debug      # verbose log in the terminal
./run_dev.sh --fake-midi  # simulated APC (no hardware needed)
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest -q tests
```

| Where | What |
|---|---|
| `~/Library/Application Support/Kinetic Kontroller/settings.json` | favorites, speed, brightness, last scene, MIDI port, per-scene settings |
| `~/Library/Application Support/Kinetic Kontroller/effects/` | your own effects (see below), no rebuild needed |
| `~/Library/Logs/Kinetic Kontroller/` | log files (also shown in the Diagnostics panel) |

## Keyboard

| Key | Action |
|---|---|
| `1` Kinetic Sweep · `2` Rainbow · `3` Mosaic · `4` Creeper · `5` Heart · `6` Kinetic Marquee | start scene |
| `0` | Blackout |
| ⌘R | Refresh MIDI |
| ⌘B | Blackout |
| ⌘⇧D | Toggle diagnostics |

To reassign keys, right-click a scene and choose **Keyboard Shortcut**. Digit shortcuts only
fire when the main window has focus, no text field is being edited, and no modifier key is
held, so normal macOS shortcuts keep working.

## Adding an effect

1. Create a file in `apc_light/effects/`, e.g. `sparkle.py`. You can copy `_template.py` to start.
2. Define an `Effect` subclass with its metadata.
3. Implement `update(ctx, frame)`.
4. That's all. Effects are discovered automatically.

```python
from apc_light.engine.effect import ColorParam, Effect


class Sparkle(Effect):
    name = "Sparkle"                  # shown in the library
    category = "Animated"             # "Static", "Animated" or "Utility"
    shortcut = "6"                    # optional
    params = [ColorParam("color", "Color", "#ffffff")]   # UI controls appear automatically

    def update(self, ctx, frame):     # called ~30×/s (static effects: only when something changes)
        frame.clear()
        for _ in range(6):
            frame.set(ctx.rng.randrange(8), ctx.rng.randrange(8), ctx.params["color"])
```

- `frame.set(x, y, color)`: `x` runs 0–7 left→right and `y` runs 0–7 **top→bottom**, as you
  see the APC. `color` is `"#rrggbb"` or `(r, g, b)`. Optional `mode="pulse"|"blink"` and
  `rate="1/2".."1/16"` use the APC's built-in animation.
- Also available: `frame.fill(color)`, `frame.clear()`, and `frame.draw_bitmap(rows, {"X": color})`.
- `ctx.t` is time in seconds, already scaled by the SPEED slider. Animate from `ctx.t` or
  `ctx.step(interval)` and speed changes just work.
- `ctx.params` holds the current settings. Available param types: `ColorParam`, `ChoiceParam`,
  `BoolParam`, `IntParam`, `FloatParam` and `TextParam`.
- Optional hooks: `start(ctx)`, `stop()`, `cleanup()`, `is_animated(params)`, and
  `on_pad_pressed(ctx, x, y, button)`.
- Helpers in `apc_light.engine.frame`: `hsv(h, s, v)`, `lerp(a, b, t)`, `scale(rgb, k)`.

In the built app, drop the same kind of file into
`~/Library/Application Support/Kinetic Kontroller/effects/` and restart the app. A broken
effect file is skipped and logged. It never stops the app.

## What the APC mini mk2 can display

| Mechanism | Per pad | Used for |
|---|---|---|
| Note On velocity → 128-colour palette | 127 colours | palette mode |
| Note On channel 0–6 → brightness 10/25/50/65/75/90/100 % | 7 levels, **per pad** | palette mode (fades) |
| Note On channel 7–10 / 11–15 → pulse / blink, done by the APC | 9 behaviours | Hardware Pulse |
| SysEx `0x24` → 24-bit RGB, ≤ 32 pads per message | any colour | RGB mode (smoothest) |

In **palette mode**, each pad gets the best of the 127 × 7 colour-and-brightness combinations
for the colour the renderer asks for, so fades use the APC's real per-pad brightness levels.
In **RGB mode**, the true colour is sent in bulk SysEx runs. In both modes, colours are snapped
to perceptually even steps before diffing, so invisible micro-changes never go out over MIDI.
**Hardware-accurate preview** (inspector) makes the on-screen APC show those quantized colours.
Switch it off to see the renderer's ideal colours instead.

## How it works

```
apc_light/
  app/application.py   bootstrap, logging, controller (UI ↔ engine ↔ settings), self-test
  engine/manager.py    Engine: single render thread, one active effect, instant switching, blackout
  engine/effect.py     Effect base class + parameter declarations
  engine/frame.py      8×8 frame + color helpers
  engine/registry.py   automatic effect discovery (package + user folder)
  midi/protocol.py     APC mini mk2 protocol: note map, Note On channels, RGB SysEx
  midi/palette.py      the APC's 128-color velocity palette
  midi/output.py       frame → MIDI, sending only changed pads
  midi/device.py       port detection, hot-plug, thread-safe sending (python-rtmidi / CoreMIDI)
  midi/input.py        MIDI IN: decode APC pads/buttons/faders -> events -> subscribers
  engine/interaction.py  which pads are held (shared by all interactive effects)
  engine/compositor.py   float canvas, blend modes, retro palette, gamma -> LED drive
  engine/touch.py        reusable touch reactions (ripple, pulses, bloom, spark)
  effects/             one file per effect
  settings/            JSON settings in Application Support
  ui/                  PySide6 (Qt) window, APC visualizer, scene library, controls
```

- **One owner.** The engine runs a single render thread for the app's whole life, with no
  per-effect threads or processes. Switching effects takes the same lock the render loop
  holds while it renders *and sends*. Once a new scene is clicked, the old one can never send
  another message, and the new scene's first frame goes out right away.
- **Input.** APC pad MIDI → `MidiInputHub` → the engine's input queue, which wakes the render
  thread immediately → `InteractionState` + `Effect.on_input` → next frame. Press → LED is one
  render, measured at about 1–6 ms. The on-screen APC posts the same events, so clicking pads works
  like pressing them. Buttons go to the GUI (scene buttons, Shift).

  ```
  MIDI IN → hub → engine input queue → interaction state → effect (layers) → compositor
          → 64-pad frame → diff vs last frame → MIDI OUT (changed pads only)
  ```
  Interactive effects never talk to MIDI. They draw layers into a `Canvas`, and the engine
  alone sends. To make an effect interactive, set `accepts_touch = True` and implement
  `on_input(ctx, event)`; `ctx.interaction.held` has the held pads. `engine/touch.py` gives you
  the reactions for free.
- **Protocol** (from the official *APC mini mk2 Communication Protocol*): pads are notes 0–63,
  with 0 at the bottom left. Note On velocity picks a palette color. The Note On channel picks
  the behavior: 0–6 are solid at 10/25/50/65/75/90/100 % brightness, 7–10 pulse, and 11–15 blink.
  SysEx `F0 47 7F 4F 24 …` sets true RGB, at most 32 pads per message. Scene buttons are
  notes 112–119 and track buttons are notes 100–107.
- **LED output** (in the inspector). **Palette** mode (the default) sends classic Note On
  messages, and brightness is the Note On channel. **RGB** mode sends SysEx 24-bit color for
  smoother gradients, and brightness scales the RGB values to the same seven levels.
- **Quit / BLACKOUT**: stops the effect and the thread, sends Note On velocity 0 to all 64 pads
  and turns off all button LEDs (plus RGB zero in RGB mode), then closes the MIDI ports.

## Hardware checklist

The automated tests use a simulated APC and a virtual CoreMIDI APC. These checks need your real controller:

1. Plug in the APC and launch the app. The header shows **● APC Mini MK2 Connected**.
2. Click **All On**. All 64 pads light white, with none missing and none in the wrong color.
3. Click **Test LEDs**. The sweep starts at the **top-left** pad and moves right, row by row, then shows full red, green, blue and white.
4. Click **Rainbow**, then quickly **Creeper**, **Heart** and **Mosaic**. Each switch is immediate and nothing flickers from the previous scene.
5. Move **Speed** while Rainbow runs. The animation speeds up and slows down smoothly.
6. Step **Brightness** from 100 % down to 10 % in both **Palette** and **RGB** mode. The pads dim in visible steps.
7. **Heart** → change the color. The APC updates immediately. Turn on **Beat**.
8. **Hardware Pulse** → the APC pulses or blinks on its own, and the on-screen grid matches.
9. **Custom Pattern** → click pads on screen and press pads on the APC. Both paint.
10. Press APC **scene button 1**. Your first favorite starts and its green LED lights. **Shift + any scene button** blacks out.
11. Press **BLACKOUT** (or `0`). Every pad and button LED goes dark.
12. Unplug the APC while a scene is running. The header shows *Not Connected*. Plug it back in: within about 2 s it shows *Connected* and the scene resumes.
13. Start **Rainbow Wave** and quit with ⌘Q. The APC goes dark.
14. Relaunch. Favorites, speed, brightness and colors are remembered, and the LEDs stay off.

### Kinetic Sweep on the hardware

1. Pick **Kinetic Sweep**: key `1`, or the **top green scene button** and don't touch anything. The band glides left and right,
   slows into each edge and turns around without jumping. Try Speed from Slow to Fast and Trails from Off to High.
2. Tap one pad. It lights **immediately**, and the ripple spreads 2–4 pads and fades back into the sweep.
3. Tap a pad rapidly, about 8 times per second. Every tap reacts and nothing stutters.
4. Press two or three pads at once, or ~150 ms apart. All reactions play and overlap.
5. Hold a pad for 3 s. It stays bright and gently breathes. Release: it fades out in about ¼ s.
6. Tap all four **corners** and edge pads with each **Reaction** style. They look right and nothing spills oddly.
7. Watch Diagnostics (footer): **touch→LED** should read under 20 ms. **pads:** shows whether your unit
   is velocity-sensitive; if it says "fixed velocity", the Velocity switch has no effect.
8. Compare **LED OUTPUT → Palette** and **RGB**. RGB should fade more smoothly; palette mode
   should still look clean, with dim trails, not flicker. Toggle **Hardware-accurate preview**
   to compare the on-screen APC with the real one.
9. While pads are animating, switch to another scene, then press **BLACKOUT**. Both take over instantly, with no leftovers.
10. Unplug the APC while holding a pad, then replug it. The sweep resumes and no pad stays stuck bright.
11. Try every preset. **PERFORMANCE** should feel tight for rhythmic tapping and **ZEN** very slow.
12. Quit while pressing pads. The APC goes dark.

If something looks wrong, open the **Diagnostics** panel (footer) and use **Copy Log**.
