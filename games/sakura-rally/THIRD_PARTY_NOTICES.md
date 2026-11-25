# Third-party notices: Sakura Rally (Android build)

## Sakura Rally (the game)

- Source: https://github.com/SummerEngine/sakura-rally, commit `4c2da60c79922a2028752221225577f504aeca46` (2026-10-12)
- Copyright (c) 2026 Summer Engine
- License: **MIT**. The full text is in [`LICENSE`](LICENSE) and ships inside the APK.
- Upstream statement: *"Code and assets are MIT, see LICENSE, except the fonts (Dela Gothic One, Yuji Syuku,
  Zen Maru Gothic), which are under the SIL Open Font License 1.1… The music and the ambience beds come
  from ElevenLabs models on fal; docs/AUDIO.md lists the prompts and the provider terms."*

## Fonts (SIL Open Font License 1.1, license texts ship in the APK under `assets/fonts/`)

- Dela Gothic One: Copyright 2020 The Dela Gothic Project Authors
- Yuji Syuku: Copyright 2021 The Yuji Project Authors
- Zen Maru Gothic: Copyright 2021 The Zen Maru Gothic Project Authors

## Music and ambience

- The music (4 tracks) was generated with ElevenLabs Music v2.5. The ambience beds were generated with ElevenLabs Sound Effects v2. Both were made through fal.ai by the upstream author.
- Upstream notes that **commercial use requires output generated under a plan with commercial rights**, and asks you to confirm the "Commercial" tag on the fal model pages before shipping commercially. See upstream `docs/AUDIO.md`.
- Engine, UI, stinger, world and voice sounds are procedural and original to the upstream repository.
- **Before a paid or ad-supported store release:** confirm the music rights with Summer Engine, or replace the four music files and the ambience beds.

## Engine

- Godot Engine 4.7.2: MIT, Copyright (c) 2014-present Godot Engine contributors and Juan Linietsky, Ariel Manzur. The engine's own third-party components are listed at https://godotengine.org/license and in the Godot source tree under `COPYRIGHT.txt`.

## Android/touch layer (this repository)

- `mobile/` (touch controls, Back-button handling, phone defaults, CI checks), `prepare.py`, the export preset and the GitHub Actions workflow: MIT, part of Game-development-3rd-party.
- The launcher icon is cropped from upstream `docs/cover.jpg` (MIT, Summer Engine).
