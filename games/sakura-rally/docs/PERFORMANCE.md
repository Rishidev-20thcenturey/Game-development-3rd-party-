# Sakura Rally on low-end Android: performance plan

**Status:** plan only. Nothing in this document has been built yet.
**Goal:** keep the look (cel shading, ink lines, petals, the long tree-lined views) and make the game run smoothly on mid-range and budget phones.

The game runs well on a Snapdragon 8 Gen 1 tablet (12 GB RAM, 1568×980 window). This document lists:
- what costs the most on a phone today, read from the upstream code (`SummerEngine/sakura-rally@4c2da60`);
- what can change without a visible difference;
- the order to do the work in.

---

## 1. What a phone renders today

The game has three quality presets, defined in `scripts/game/quality.gd`. **The default is `high`** (see `scripts/autoload/game.gd`, setting `"quality"`). `Quality.apply()` runs on every map load. It **overrides** the phone settings our build writes into `project.godot`: MSAA off and a 2048 shadow map.

So today, on every phone, the game draws:

| Setting | Value on a phone now | Notes |
|---|---|---|
| Anti-aliasing | **MSAA 4×** | Set at runtime by the `high` preset. |
| Sun shadow map | **8192 × 8192** atlas, **4 cascades**, out to **320 m** | About **256 MB of video memory** for the shadow atlas alone. A budget phone has 3–4 GB of RAM in total, shared with the GPU. |
| 3D resolution | **Native** (scale 1.0) up to a 1920×1080 pixel budget | 1568×980 on the tablet. FSR only starts above 1080p. |
| Frame rate | **Uncapped up to the screen refresh** | `project.godot` has no `max_fps` or frame cap. On a 90/120 Hz screen the GPU tries to draw 90–120 frames a second, and the phone heats up and slows itself down (thermal throttling) after a few minutes. |
| Physics | Jolt at **120 Hz**, up to **12 steps per frame** | When a frame is slow, the next one runs more physics steps, which makes it slower still. Budget CPUs can fall into this "spiral". |
| Props | **67,107** instanced props in 96 chunks | Trees are visible to **1,300 m**, buildings to 900 m (`MapWorld.CATEGORY_VIEW`). |
| Outlines | Every toon material has an **outline hull `next_pass`** (`toon_materials.gd`) | Outlined meshes are drawn twice. |
| Screen passes | Ink lines (`post_ink`: screen texture and depth texture), colour grade (`post_grade`: screen texture), glow | Reading the screen and depth textures forces extra copies on the Mobile renderer. |
| UI | `paper_card` and `backdrop_blur` read the screen texture with mipmaps | Cost only on menus and the pause screen. |

The **Low** preset already exists and is choosable in Settings → Quality: FXAA, 0.75 render scale, a 2048 shadow map with 2 cascades to 160 m, 60% view distance, no vegetation shadows and no glow. But:
- players don't know to choose it;
- it switches off glow and vegetation shadows, which you *can* see.

---

## 2. Changes ranked by benefit per visual cost

"Visible?" is judged at phone screen size.

### Tier A: no visible difference (do these first)

| # | Change | Where | Expected gain | Visible? |
|---|---|---|---|---|
| A1 | **Cap the frame rate at 60** (with a 30 fps option in Settings) | mobile layer: `Engine.max_fps` | Biggest win for *sustained* smoothness. It stops the 120 Hz over-drawing and thermal throttling, and saves battery. | No |
| A2 | **Mobile shadow map: 2048 atlas, 2 cascades, 200 m** instead of 8192 / 4 / 320 m | new `mobile` preset (see §3) | About −240 MB VRAM, and far fewer shadow draw calls. Cel shadows are hard-edged bands, so 2048 looks the same on a 6–11" screen. | No (needs a side-by-side check) |
| A3 | **Limit physics catch-up to 4 steps per frame** (`max_physics_steps_per_frame` 12 → 4) | `prepare.py` project override | Stops the slow-frame spiral on weak CPUs. The handling is unchanged because the tick stays 120 Hz. | No |
| A4 | **Shader warm-up** behind the loading screen: draw every material, particle and post pass once, off-camera | mobile layer, hooked to `MapWorld.build_progress` | Removes the first-lap stutters, which are pipeline compiles the first time a material is seen. | No |
| A5 | **Anti-aliasing:** MSAA 4× → **2×** (tile-based GPUs resolve MSAA on-chip, so 2× is cheap) | `mobile` preset | Lower bandwidth and memory. The ink lines hide most edge aliasing anyway. | Barely |

### Tier B: tiny visual cost, large gain

| # | Change | Expected gain | Visible? |
|---|---|---|---|
| B1 | **Render scale 0.8–0.85 with FSR 1** on phones (keep 1.0 on tablets above a size threshold) | About −30% pixel shading. Upstream already designed for this: *"the ink lines and cel bands survive the upscale"* (`quality.gd`) | Slightly softer textures, but the lines stay sharp |
| B2 | **Fade outline hulls beyond about 150 m.** At that distance `post_ink` already draws the silhouette lines from depth | Up to half the vertex work on distant props | Very slight: distant outlines get thinner |
| B3 | **Mesh LOD bias per preset.** All 106 `.glb` imports already have `meshes/generate_lods=true`, so Godot has LODs. Raise `mesh_lod_threshold` (the viewport's LOD threshold) to 1.5–2 px on phones so the lower LODs kick in sooner | Fewer triangles in the forest | No (the fog and ink lines cover it) |
| B4 | **Tree draw distance 1,300 m → 900 m**, with fog start tuned so the horizon looks the same | Fewer far chunks drawn | Very slight |
| B5 | **Dust particles:** use the existing `medium` count (`car_fx.gd`: 96 → 64 per emitter) on the `mobile` preset | Less overdraw when sliding on gravel | Barely |

### Tier C: visible, for genuinely weak devices only (an opt-in "Battery saver" preset)

- Glow off, vegetation shadows off (today's `low`).
- 0.67 render scale.
- 30 fps cap.
- The colour-grade pass merged into the ink pass (one full-screen pass instead of two). This last item needs a shader edit, done in `prepare.py`.

---

## 3. A `mobile` preset with automatic device tiers

Add a fourth preset, plus first-launch auto-detection, without forking upstream. We patch `quality.gd` from `prepare.py`, the same way the build already patches other files.

```
"mobile": { msaa 2×, fxaa off, scale 0.85, shadow_atlas 2048, shadow_splits 2,
            shadow_distance 200, view 0.8, vegetation_shadows true, glow true }
```

On first launch, if the player has never changed Quality, the game picks a preset:

| Device tier | How it is detected | Preset | FPS cap |
|---|---|---|---|
| High (SD 8 Gen 1+, Dimensity 9000+, ≥ 8 GB RAM) | `RenderingServer.get_video_adapter_name()` (e.g. "Adreno (TM) 730") and `OS.get_memory_info()` | `mobile`, scale 1.0 | 60 |
| Mid (Adreno 6xx, Mali-G68/G77, 6 GB) | same | `mobile` | 60 |
| Low (Adreno 610/619, Mali-G52/G57, ≤ 4 GB) | same | `low` + B-tier changes | 30 (60 selectable) |
| Unknown | n/a | `mobile` | 60 |

**Dynamic resolution (optional, after the above):**
- Every 2 s, read `Performance.TIME_PROCESS` and the GPU frame time.
- Nudge `scaling_3d_scale` between 0.67 and 1.0 to hold the target frame rate.
- This keeps the look on good devices and protects frame rate on weak ones.

---

## 4. Measuring it (no guessing)

1. **In-game performance overlay** in the mobile layer, toggled by a three-finger tap. It shows FPS, frame time, draw calls (`RENDER_TOTAL_DRAW_CALLS_IN_FRAME`), video memory (`RENDER_VIDEO_MEM_USED`) and the active preset. It can also write a CSV to `user://perf.csv` for sharing.
2. **Benchmark run:** upstream ships a trained neural driver (`scripts/ai/auto_drive.gd`, which can drive the player's car in Time Attack). A "Benchmark" entry drives Hanami Pass by itself for 90 s and reports average, 1% low and worst frame. The result is comparable across phones because the route and camera are the same every time.
3. **Reference devices:** the Snapdragon 8 Gen 1 tablet (high), plus at least one budget phone, e.g. Snapdragon 680 / Helio G85 / Exynos 850 class (Redmi Note 11/12, Galaxy A13/A14).
4. **Targets:**
   - Mid tier: steady 60 fps.
   - Low tier: steady 30 fps.
   - After warm-up: no frame over 50 ms during a stage, and video memory under 700 MB.
   - On the tablet: no visible difference in side-by-side screenshots of the title, a stage start and a forest corner.
5. **CI:** the build already produces Mobile-renderer screenshots (`docs/ci/*.jpg`). Add the same shots rendered with the `mobile` preset, so every change can be compared side by side with the current look.

---

## 5. Order of work

1. **A1 + A3 + A2 + A5** (a frame cap, physics steps, shadow and AA via a `mobile` preset) plus the auto-pick. This is small: a few dozen lines in the mobile layer and `prepare.py`, and it gives most of the gain.
2. The performance overlay and benchmark. Then measure on the tablet and one budget phone.
3. **A4** shader warm-up (stutter).
4. B-tier items, each kept only if the side-by-side screenshots show no difference.
5. Dynamic resolution and a "Battery saver" preset.

**Upstream rule:** all of this goes in `games/sakura-rally/mobile/` and in `prepare.py` patches. The upstream game is downloaded unmodified at build time, so new upstream versions keep working.

---

## 6. Known non-goals and risks

- **Physics tick stays at 120 Hz.** The car handling and the replays (`replays.gd` records `tick_rate`) are tuned for it. Moving to 60 Hz would change how the car feels.
- **The GL Compatibility fallback** (already enabled for phones without Vulkan) looks a bit different: some post effects are simplified. Treat it as a "runs at all" path, not a quality target.
- **APK size (86 MB)** comes mostly from the world file (`map.bin`, 45 MB raw) and audio (30 MB). It does not affect frame rate. If Play Store size matters later, consider shipping the AAB with Play Asset Delivery.
