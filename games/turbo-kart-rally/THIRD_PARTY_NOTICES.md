# Third-party notices — Turbo Kart Rally (Android build)

This app is a repackaged, mobile-adapted build of a third-party open-source game.

## Turbo Kart Rally (the game)

- Source: https://github.com/bridge-mind/turbo-kart-rally (commit `c52aca3`, "Initial release of Turbo Kart Rally")
- Copyright (c) 2026 BridgeMind
- License: MIT. The full text is in [`LICENSE`](LICENSE) and is shipped in the APK as `assets/www/LICENSE.txt`.
- Changes in this repository (also MIT): offline vendoring of Three.js and fonts, touch controls
  (`web/src/touch.js`), the mobile layout (`web/src/mobile.css`), platform detection
  (`web/src/platform.js`), a lower pixel-ratio cap and shadow-map size on touch devices
  (`web/src/main.js`, `web/src/environment.js`), and the Android wrapper (`android/`).

## three.js r170

- https://github.com/mrdoob/three.js — Copyright © 2010-2024 three.js authors
- License: MIT ([`web/vendor/three/LICENSE`](web/vendor/three/LICENSE))

## Fonts

- **Lilita One**, Copyright 2011 Juan Montoreano — SIL Open Font License 1.1 ([`web/vendor/fonts/LICENSE-LilitaOne-OFL.txt`](web/vendor/fonts/LICENSE-LilitaOne-OFL.txt))
- **Nunito**, Copyright 2014 The Nunito Project Authors — SIL Open Font License 1.1 ([`web/vendor/fonts/LICENSE-Nunito-OFL.txt`](web/vendor/fonts/LICENSE-Nunito-OFL.txt))
- Files are from the `@fontsource/lilita-one` and `@fontsource/nunito` npm packages.

## App icon

- `android/icon-source.jpg` and the launcher icons were made with AI for this repository. They do not come from the upstream project.

## Build toolchain (not shipped in the APK)

The toolchain is listed in `tools/android/fetch-toolchain.sh`: aapt2, dx (AOSP), apksigner and android.jar (Apache-2.0), ecj (EPL-1.0) and the Temurin JRE (GPLv2 with Classpath Exception).
