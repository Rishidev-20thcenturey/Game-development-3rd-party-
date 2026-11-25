# How the first game was picked

Date: 2026-11-25. Source catalogue: [awesome-opus-5.5-games](https://github.com/Rishidev-20thcenturey/awesome-opus-5.5-games) (`games.json`, 4,128 repositories).

## Method

1. **Filter the catalogue.** Keep `quality_category = curated_games`. Keep browser-engine tech (HTML/JS, Three.js, Phaser, Canvas, WebGL, PixiJS, Babylon) and drop Unity, Godot, Unreal and Roblox. 2,849 games remain.
2. **Check licenses on GitHub.** Take the top 900 by quality score and read each repository's detected license through the GitHub GraphQL API. Results: **130 MIT**, 684 with no license at all (can't be redistributed), and the rest GPL, AGPL, Apache or other.
3. **Rank the MIT games for an Android build.** Criteria:
   - quality score and screenshot score from the catalogue
   - a **static web build with no server, accounts or API keys**, so it can ship offline inside an APK
   - **small and self-contained**, with no huge asset folders
   - **easy to port**: no build step is best; Vite is acceptable
   - a **real, complete game loop**, not a demo

## Shortlist (MIT only)

| Game | Repo | Quality | Screenshot | ★ | Size | Notes |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| **Turbo Kart Rally** ✅ | bridge-mind/turbo-kart-rally | 9.3 | **9.8** (best in the catalogue) | 53 | 1.2 MB | Plain ES modules, no build step, every asset generated in code, full race loop with 8 racers, 8 items, AI, menus and results. Needed touch controls. |
| Turbo Kart Rush | bridge-mind/turbo-kart-rush | 9.0 | 8.7 | 48 | 1.1 MB | Same studio, Vite/TS. Runner-up. |
| Just Five More Minutes | Giftedx/just-five-more-minutes | 9.5 | 7.5 | 0 | 4.1 MB | Strong, but the visuals are weaker. |
| Silent Meridian | stackloomdev/silent-meridian | 9.1 | 9.0 | 2 | 17.4 MB | Good visuals, much heavier. |
| PixelArtGameOpus | Odiriuss/PixelArtGameOpus | 8.9 | 8.7 | 8 | 1.2 MB | Canvas 2D collection, a good small candidate. |
| Nova Lancer | tanuu5/nova-lancer | 8.7 | 8.2 | 12 | 2.8 MB | Three.js shooter, light. |
| Tater's Flight Sim | JaredTate/tatertotsflightsim | 9.2 | 8.2 | 10 | 39.8 MB | Heavy assets. |
| P(DOOM) | transitive-bullshit/ai-safety-doom | 9.3 | 8.0 | 7 | 44.5 MB | Next.js app, harder to make offline. |
| Rogue Squadron — Battle of Yavin | PhiloLabs/fable51-worlds | 9.0 | 8.6 | 534 | 417 MB | Monorepo, and it's Star Wars IP, so not publishable. |

## Why Turbo Kart Rally

- It has the highest visual rating in the whole catalogue and a 9.3 quality score.
- It's MIT licensed (© 2026 BridgeMind), with a full license file in the repo.
- It has **no asset files**. Meshes, textures, audio and music are all generated at runtime, so the APK is about **0.6 MB**.
- There's no build step and no backend, so it runs fully offline with no INTERNET permission.
- It already supports gamepads. Touch controls and a phone layout were the only big missing pieces, and both have now been added.

## Things to fix before a store release

The game is openly "a clone of Mario Kart". Its code and art are original, but some names are close to Nintendo's: racers called *Toadly* and *Koopz*, and items called *mushroom*, *green/red/blue shell* and *star*. **Rename these, and avoid "Mario Kart" in the store listing, before publishing on Google Play.** The MIT license covers the code, not someone else's trademarks.
