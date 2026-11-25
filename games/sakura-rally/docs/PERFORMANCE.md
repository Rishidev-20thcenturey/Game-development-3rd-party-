# Sakura Rally on low-end Android: CPU and GPU load plan

**Status:** plan only. Nothing in this document has been built yet.
**Goal:** lower the **CPU and GPU work per frame** so the game holds a steady frame rate on mid-range and budget phones, **without changing the look**: cel shading, ink lines, petals and the long tree-lined views.

The game runs well on a Snapdragon 8 Gen 1 tablet (1568×980 window). Everything below was read from the upstream code (`SummerEngine/sakura-rally@4c2da60`). The frame-cost estimates still need to be measured on devices (§4).

A frame is smooth only when **both** of these fit in the frame budget (16.6 ms for 60 fps, 33.3 ms for 30 fps):
- **CPU:** game scripts, physics, and preparing and sending draw calls.
- **GPU:** vertices, pixels and full-screen passes.

On budget phones (Snapdragon 680, Helio G85, Exynos 850 class) both are about 3–5× slower than an 8 Gen 1. So each change below is labelled with the side it helps.

---

## 1. Where the load comes from today

The game's own default quality preset is **`high`** (`scripts/game/quality.gd`, `scripts/autoload/game.gd`). It is applied on every map load and overrides the phone settings our build puts in `project.godot`. **However, our mobile layer switches a fresh install to `low`** (`mobile.gd`, `_first_run_defaults`). So phones start on Low unless the player picks another preset in Settings.

**First real measurement:** Snapdragon 8 Gen 1 tablet, 144 Hz screen: **about 40 fps**, on Low unless changed. So the frame cost is mostly *not* in what the presets switch. The tables below list every cost source; the **performance lab** in the test build (§8) measures which one dominates.

### CPU load

| Source | What happens | Why it costs |
|---|---|---|
| **No frame cap** | No `max_fps` set. On a 90/120 Hz screen the game tries to run 90–120 frames per second. | All CPU work (scripts and draw calls) runs up to twice as often as needed. The chip heats up and throttles after a few minutes, then frame rate drops. |
| **Car physics in GDScript at 120 Hz** | `car.gd` `_integrate_forces` runs a custom 4-wheel tyre and drivetrain model in script, 120× a second. | Script math is slow on weak CPUs. In **Race** mode there are **7 cars** (player + `Game.RIVALS` 6), so about 840 car steps a second. The car already measures its own cost (`step_usec`), which helps measuring. |
| **Physics catch-up** | `max_physics_steps_per_frame=12` | One slow frame makes the next frame run up to 12 physics steps, which makes it slower still. Weak CPUs can fall into this spiral. |
| **Draw-call submission** | 67,107 props in 96 prop types, in 160 m chunks. Trees are drawn to **1,300 m**, buildings to 900 m. | Each visible chunk × prop type is a draw call. |
| ×**outline pass** | Every toon material has an outline hull `next_pass` (`toon_materials.gd`) | Outlined objects are submitted twice. |
| ×**4 shadow cascades** | The sun's shadows use 4 splits out to 320 m | Shadow casters are culled and submitted again for each cascade, so up to 4 extra passes over the scene. This is usually the biggest CPU render cost in a forest. |
| **Per-frame scripts** | 45 scripts with `_process`/`_physics_process`: crowds, car FX and skid marks, season blending, HUD, AI | Each is small; together they add up. |
| **AI rivals** | Neural network (46→128→128→12) per rival | Already cheap: it decides only every 12 ticks (10 Hz, `DriveHands.DECISION_TICKS`). Not a priority. |

### GPU load

| Source | What happens | Why it costs |
|---|---|---|
| **No frame cap** | Same as above | The GPU draws up to 120 frames a second instead of 60. |
| **Native resolution** | 3D at full window resolution (scale 1.0; FSR only above 1080p) | Pixel work is the biggest GPU cost on phones. |
| **MSAA 4×** | Set by the `high` preset | Four samples per pixel on every edge, plus resolve bandwidth. |
| **Shadow maps** | 8192 atlas, 4 cascades | Rendering 4 shadow views every frame, at high resolution. |
| **Full-screen passes** | Ink lines (`post_ink`: reads screen and depth), colour grade (`post_grade`: reads screen), glow | Each one reads the whole screen again. Reading screen and depth forces extra copies on the Mobile renderer. |
| **Outline hulls** | Second draw of outlined meshes | Double the vertex work for those objects. |
| **Transparent overdraw** | Petals, dust (96 particles per emitter on `high`), clouds, water | Pixels shaded several times over. |
| **Menu blur** | `backdrop_blur` and `paper_card` read the screen with mipmaps | Menus and pause screen only. |

---

## 2. Changes, ranked by load saved per visual cost

### Tier A: no visible difference (do first)

| # | Change | CPU | GPU | Visible? |
|---|---|:-:|:-:|---|
| A1 | **Cap at 60 fps** (`Engine.max_fps`), with a 30 fps "battery" option in Settings. Up to half the work on 90/120 Hz screens, and no thermal throttling, so the frame rate stays steady. | ✅✅ | ✅✅ | No |
| A2 | **Shadows: 2 cascades to 200 m, 2048 map** (was 4 / 320 m / 8192). Halves the shadow passes. Cel shadows are hard-edged bands, so the lower resolution doesn't show on a phone screen. | ✅✅ | ✅✅ | No (needs a side-by-side check) |
| A3 | **Physics catch-up limited to 4 steps per frame** (was 12). Ends the slow-frame spiral. The tick stays 120 Hz, so the handling is identical. | ✅✅ | n/a | No |
| A4 | **Skip effects for off-screen and distant rivals**: no dust or chips, skid marks or engine-audio detail more than about 150 m away or behind the camera. Physics untouched, so races stay fair. | ✅ | ✅ | No |
| A5 | **MSAA 4× → 2×.** Tile-based phone GPUs resolve 2× cheaply on-chip, and the ink lines already hide edge stair-steps. | n/a | ✅ | Barely |
| A6 | **Shader warm-up** during the loading screen: draw every material, particle and post pass once. This removes first-lap stutter (shader compiles), which is frame-time *spikes* rather than average load. | ✅ (spikes) | ✅ (spikes) | No |
| A7 | **Try Godot's multi-threaded rendering** (`rendering/driver/threads/thread_model = Separate`). Draw-call preparation moves off the main thread onto another core. Must be tested for stability on Godot 4.7 Android before shipping. | ✅✅ | n/a | No |

### Tier B: tiny visual cost, large saving

| # | Change | CPU | GPU | Visible? |
|---|---|:-:|:-:|---|
| B1 | **Render scale 0.8–0.85 + FSR 1** on phones (1.0 on large tablets). About 30% fewer pixels shaded. Upstream already designed for it: *"the ink lines and cel bands survive the upscale"* (`quality.gd`). | n/a | ✅✅✅ | Slightly softer textures; lines stay sharp |
| B2 | **Outline hulls only within about 150 m.** Beyond that, `post_ink` already draws silhouettes from depth. Fewer draw calls *and* vertices. | ✅✅ | ✅✅ | Very slight |
| B3 | **Lower LODs sooner.** All 106 `.glb` imports already have `generate_lods=true`; raise the viewport `mesh_lod_threshold` to about 1.5–2 px on phones. | n/a | ✅ | No (fog and ink lines cover it) |
| B4 | **Trees 1,300 → 900 m, buildings 900 → 700 m**, with fog start retuned so the horizon looks the same. Fewer chunks culled and submitted. | ✅✅ | ✅ | Very slight |
| B5 | **Dust 96 → 64 per emitter** (the existing `medium` value in `car_fx.gd`). Less overdraw when sliding. | n/a | ✅ | Barely |
| B6 | **Merge the colour grade into the ink pass**: one full-screen read instead of two. It is a shader edit done from `prepare.py`, with an identical image if done right. | n/a | ✅ | No (needs a pixel diff check) |

### Tier C: visible, opt-in "Battery saver" only for very weak phones

- Glow off.
- No vegetation shadows.
- 0.67 render scale.
- 30 fps cap.

This is today's `low` preset plus the cap.

---

## 3. A `mobile` preset with automatic device tiers

We add a fourth preset by patching `quality.gd` from `prepare.py`. The upstream game stays unmodified at download time.

```
"mobile": { msaa 2×, scale 0.85, shadow_atlas 2048, shadow_splits 2, shadow_distance 200,
            view 0.8, vegetation_shadows true, glow true }   + fps cap 60, physics steps 4
```

On first launch, if the player never touched Quality, the game picks one by **GPU and CPU class**, read from `RenderingServer.get_video_adapter_name()` (e.g. "Adreno (TM) 730", "Mali-G52") and `OS.get_processor_count()`/`OS.get_processor_name()`:

| Tier | Example chips | Preset | Cap |
|---|---|---|---|
| High | Snapdragon 8 Gen 1+ (Adreno 7xx), Dimensity 9000+ (Mali-G710+) | `mobile`, scale 1.0 | 60 |
| Mid | Snapdragon 7xx (Adreno 6xx), Dimensity 7xxx, Mali-G68/G77 | `mobile` | 60 |
| Low | Snapdragon 680/695 (Adreno 610/619), Helio G85/G99, Exynos 850 (Mali-G52/G57) | `low` + B-tier changes | 30 (60 selectable) |
| Unknown | n/a | `mobile` | 60 |

**Dynamic resolution (after the above):**
- Measure GPU frame time with `RenderingServer.viewport_set_measure_render_time` and `viewport_get_measured_render_time_gpu`.
- If the GPU is the bottleneck, nudge `scaling_3d_scale` between 0.67 and 1.0 to hold the target.
- Good devices keep full sharpness; weak ones drop a little resolution only in heavy scenes.

---

## 4. Measuring it: find out if a phone is CPU-bound or GPU-bound

1. **Performance overlay** in the mobile layer (three-finger tap) showing:
   - **CPU:** frame time, `Performance.TIME_PROCESS`, `TIME_PHYSICS_PROCESS`, the car's own `step_usec`, draw calls (`RENDER_TOTAL_DRAW_CALLS_IN_FRAME`);
   - **GPU:** measured GPU render time per frame;
   - which side is the bottleneck: whichever time is closer to the frame budget.

   It also writes `user://perf.csv` for sharing.
2. **Benchmark lap:** upstream's trained neural driver (`scripts/ai/auto_drive.gd`) drives Hanami Pass by itself for 90 s. It reports average fps, 1% low, worst frame, and CPU vs GPU time. Run it once in Time Attack (1 car) and once in Race (7 cars, the heaviest CPU case).
3. **Reference devices:** the 8 Gen 1 tablet, plus one budget phone (Redmi Note 11/12, Galaxy A13/A14 class).
4. **Targets:**
   - Mid tier: steady 60 fps.
   - Low tier: steady 30 fps.
   - After warm-up: no frame over 50 ms during a stage.
   - Frame rate after 10 minutes within 10% of the first minute (no throttling).
   - On the tablet: no visible difference in side-by-side screenshots (title, stage start, forest corner).
5. **CI:** the build already renders Mobile-renderer screenshots (`docs/ci/*.jpg`). Add the same shots with the `mobile` preset for side-by-side comparison on every change.

---

## 5. Order of work

1. **A1 + A2 + A3 + A5** via the `mobile` preset, plus auto-pick. A few dozen lines; most of the CPU and GPU saving.
2. The overlay and benchmark. Measure on the tablet and one budget phone to learn whether each is CPU- or GPU-bound.
3. If **CPU-bound:** A4, A7, B2, B4. If **GPU-bound:** B1, B6, B3, B5, then dynamic resolution.
4. A6 shader warm-up (stutter spikes).
5. Battery-saver preset.

**Rule:** everything goes in `games/sakura-rally/mobile/` and `prepare.py` patches, so new upstream versions keep working.

---

## 6. Out of scope and risks

- **Physics stays at 120 Hz.** The handling and replays (`replays.gd` stores `tick_rate`) are tuned for it, and 60 Hz would change how the car feels. A3 limits catch-up only.
- **Rival physics stays full-rate** for race fairness. Only their visual and audio extras are trimmed (A4).
- **The GL Compatibility fallback** (phones without Vulkan) simplifies some post effects. It is a "runs at all" path, not a look target.
- Lower memory use is a side effect of A2/A5 (the shadow atlas drops from about 256 MB to 16 MB), not the goal.

---

## 7. 120 fps on high-refresh screens

Reaching 120 fps needs two things.

**1. The screen must actually switch to 120 Hz for the game.**
- Godot 4.7.2's Android code never asks for a refresh rate. There is no `Surface.setFrameRate` or `preferredDisplayModeId` anywhere in `platform/android/java` at tag `4.7.2-stable`.
- So Android, or the maker's game service (e.g. Samsung Game Booster), decides, and it often keeps games at 60 Hz.
- **Fix, in the mobile layer, no engine change:** Godot 4.4+ exposes the Android activity to scripts through the `AndroidRuntime` singleton and `JavaClassWrapper`.
  1. On launch, read `Display.getSupportedModes()`.
  2. Pick the highest-refresh mode at the current resolution.
  3. Set the window's `preferredDisplayModeId` on the UI thread (`runOnUiThread`).

  `preferredDisplayModeId` is a plain Java field and the wrapper only calls methods, so it is set via `Class.getField(...).setInt(...)`. This must be checked on a real device.

**2. Every frame must finish in 8.3 ms, on both CPU and GPU.**
- **Good news:** physics already ticks at 120 Hz, so at 120 fps every frame gets exactly one physics step, which is the smoothest possible case.
- **Hard part:** the desktop `high` preset (MSAA 4×, 8192 / 4-cascade shadows, 3 full-screen passes, native resolution) is unlikely to fit in 8.3 ms on a phone GPU in the forest sections, even on a Snapdragon 8 Gen 1. And the 8 Gen 1 throttles under long full load.
- **Realistic route:** apply Tier A plus B1 (85% render scale with FSR). Expected: 120 in open sections and 90–120 in dense forest on the 8 Gen 1. Only the overlay (§4) can confirm it.

**Settings to ship:**
- Frame rate: **Auto (match screen) / 120 / 90 / 60 / 30**.
- On Auto, drop to 90 or 60 if the device stays above about 45 °C or misses frames for 10 s (`Performance` frame times plus Android thermal status).
- 120 fps uses roughly twice the battery and heat of 60, so it should be the player's choice.

---

## 8. Performance meter and lab (in the APK)

`mobile/perf_lab.gd`, shown on phones.

**The meter** sits in the top-right corner and shows:
- fps, frame time and the worst frame;
- **CPU** time split into scripts, physics × steps per frame and render submission;
- **GPU** time;
- which side is the **limit** (CPU, GPU, frame cap or screen);
- draw calls, triangles, the 3D resolution, the screen refresh rate and the quality preset.

**Tap the meter** to pause and open the lab. Each switch changes one cost, live:

| Switch | Values | What it tells us |
|---|---|---|
| Frame-rate cap | Screen max / 120 / 90 / 72 / 60 / 48 / 30 | Even frame pacing: 72 and 48 divide 144 Hz evenly. Also less heat. |
| 3D resolution | Game / 100% / 85% / 70% / 50% | If fps rises a lot at 50%, the GPU is fill-bound (pixels). If not, look at the CPU or vertices. |
| Sun shadows | On / OFF (test) | Cost of the shadow passes (CPU draw calls and GPU vertices). |
| Ink lines | On / OFF (test) | Cost of the full-screen ink pass, which reads the screen and depth. |
| Colour grade | On / OFF (test) | Cost of the second full-screen pass. |
| Copy report | n/a | Puts device, GPU, renderer, switches and the meter numbers on the clipboard. |

The "test" switches change the look. They exist only to find the cost, and they reset on every launch. The real fix then targets that cost without changing the look, using the matching item in §2.

The build also limits physics catch-up to 4 steps per frame on phones (A3).
