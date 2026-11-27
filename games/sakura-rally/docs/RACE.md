# Sakura Rally: race mode on mobile

Race mode (6 rivals, 2 laps) is upstream's: Main builds the grid, RaceField keeps the order,
and a `RaceBot` drives each rival (the shipped neural driver plus a pace limiter and traffic
rules). This build adds a layer in `mobile/race/`. It changes how the rivals race and what a
race costs. It does not touch the driving model or the network's weights.

| File | What it does |
|---|---|
| `mobile/race/race_bot_plus.gd` | `RaceBot` subclass. Main uses it for every rival (one line patched by `prepare.py`). |
| `mobile/race/fast_policy.gd` | The same network evaluated in 4×4 blocks (`Projection × Vector4`). |
| `mobile/race/race_director.gd` | Added to every `RaceField` by `mobile.gd`: decision phases, rails, catch-up and best race lap. |
| `mobile/ci/race_check.gd` | CI: batched network vs `DrivePolicy`, and a full race with rails off then on. |
| `mobile/ci/race_battle.gd` | CI: upstream's `race_probe` with `bot=plus` or `bot=upstream`, so the racing stats can be compared. |

## Why the rivals felt slow and timid

* **Pace.** A rival's lap target is gold × its campaign factor (0.97–1.25). Turned into a bot
  pace by the calibration table, that is about 0.60–0.77 of the driver's recorded speed. A
  player who beats gold laps faster than the whole field.
* **Traffic rules.** Upstream lifts at a time-to-collision of 1.5 s and brakes at 1.0 s. It only
  passes a car at least 1 m/s slower, and it moves over for any car behind that is 0.3 m/s faster.
* **Cost.** Every rival is a full rigid body with a tyre model (about 0.7 ms per 120 Hz tick on
  the Adreno 730 tablet). The network takes about 24,000 interpreted multiply-adds per decision.
  With six rivals, a race costs several ms per frame more than a time trial.

## What changes

### Racecraft (`race_bot_plus.gd`)

| | Upstream `RaceBot` | `race_bot_plus.gd` |
|---|---|---|
| Following gap | 2 m + 0.35 s | 2 m + 0.25 s |
| Lift / brake TTC | 1.5 s / 1.0 s | 1.15 s / 0.8 s |
| Pass a car slower by | 1.0 m/s, within 40 m | 0.5 m/s, within 50 m |
| Corner braking with a car close ahead | 4 m/s² | 5 m/s² (brakes later) |
| Slipstream (car ahead in lane, 5–30 m, > 18 m/s) | — | pace limit +5% |
| Player close behind (1–22 m) | moves over | covers the player's line once, for up to 3 s; again only after 4 s clear |
| Yields to another bot | 0.3 m/s faster | 1.5 m/s faster |

The rules RaceBot uses to avoid collisions stay as they are: it never steers towards a car
alongside, it makes room for a car alongside, and it keeps its rescue logic.

### Pace

The campaign pace stays as the minimum. If you have a record on the stage (your time-trial best
minus 3 s for the standing start, or your best race lap), the field is spread around it. Pole,
which is the slowest car, targets 1.10 × your lap. The last car on the grid targets 0.97 × your
lap. A faster player meets faster rivals.

The director adds a light catch-up. From 60 m up to 400 m of road ahead of you, a rival eases by
up to 5%. Behind you, it speeds up by up to 8%, but never beyond pace 1.0.

### Rails (`race_director.gd`)

A rival that cannot be seen leaves the physics world. That means more than 185 m from the camera,
or more than 55 m away and outside the view. It also has to be more than 50 m of road from your
car, upright, on the road, and not being rescued. The director disables its node
(`PROCESS_MODE_DISABLED`), which removes the rigid body from Jolt and stops its tyre model,
network and sound. It then moves the car along its lane at the speed its own pace limiter allows,
braking for corners as the bot would. It keeps 9 m to a car ahead in the same lane and passes a
slower one on the free side. A ground ray every 6 ticks keeps the car on the surface.

The car wakes before it can be seen or touched. That happens within 160 m and in view, within
42 m anywhere, within 40 m of road from your car, or when the spot one second ahead comes into
view. On waking it rejoins physics at its speed, with its wheels spinning to match, in a gear that
fits, and with its network deciding on the same tick. RaceField keeps classifying it all along.

### Network (`fast_policy.gd`)

The weights are packed once into `Projection` blocks, so one interpreted step does 16
multiply-adds in native code. That is about 1,500 steps per decision instead of 24,000. The
logits agree with `DrivePolicy` to about 1e-5 (float32 sums), so it chooses the same options.
The director also spreads the six rivals' decisions evenly over the 12-tick cycle. Before, they
fell in ticks 0–5, so at 30 fps one frame ran four decisions and the next ran none.

## Checks (CI)

* `race_check.gd`: the network comparison, then the same race twice (rails off, rails on) with a
  RaceBot driving your car. It reports the physics tick time, the cars' own physics per tick,
  the share of rival ticks on rails, every woken car watched for 3 s, flips, rescues, places
  gained and finish times.
* `race_battle.gd`: upstream's race probe, `bot=upstream` vs `bot=plus`: lap errors, overtakes,
  contacts, rescues, flips and the decision cost (COST line).
* `mobile_check.gd` (rendered run): the grid, the pack and the perf meter in a race. The meter
  shows "N on rails".
* The upstream `flows.gd` race checks still run against the patched game.
