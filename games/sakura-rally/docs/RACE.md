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
| Following gap | 2 m + 0.35 s | 2 m + 0.30 s |
| Lift / brake TTC | 1.5 s / 1.0 s | 1.3 s / 0.9 s |
| Pass a car slower by | 1.0 m/s, within 40 m | 0.5 m/s, within 50 m |
| Corner braking with a car close ahead | 4 m/s² | 4.5 m/s² (brakes a little later) |
| Slipstream (car ahead in lane, 5–30 m, > 18 m/s) | — | pace limit +5% |
| Player close behind (1–14 m) | moves over | covers the player's line once, for up to 2 s; again only after 4 s clear |
| Yields to another bot | 0.3 m/s faster | 1.5 m/s faster |

The rules RaceBot uses to avoid collisions stay as they are: it never steers towards a car
alongside, it makes room for a car alongside, and it keeps its rescue logic.

### Pace

The field runs at about 80% of the driver's own speed. Pole, the slowest car, runs at 0.75 and the
last car on the grid, the fastest, at 0.88. The others are spread between, and no rival is ever
slower than its campaign lap. On Hanami that is a 1:47–2:03 lap; gold is 2:04.5. Before this, the
campaign paces put the field at 0.60–0.77.

If you have a record on the stage and it asks for more, the field is also set from your own lap.
Your record is your time-trial best minus 3 s for the standing start, or your best race lap. Pole
then targets 1.06 × your lap and the fastest car 0.95 ×, a little quicker than you. Each rival
takes the faster of the two. Nothing runs above 0.95.

The director adds a light catch-up. From 60 m up to 400 m of road ahead of you, a rival eases by
up to 5%. Behind you, it speeds up by up to 8%, but never beyond 0.95.

### Steadiness

* **Lane changes.** A new lane target has to be wanted at two decisions in a row (0.2 s) before
  the car moves for it. A car alongside, or a car to pass within 14 m, still gets an immediate
  reaction.
* **Slipstream.** The tow only lifts the pace limit where the car is still accelerating, never
  into a braking zone.
* **Braking.** With a car close ahead, corner braking assumes 4.5 m/s² (upstream 4.0), down from
  the earlier 5.0, so the car doesn't overshoot at the higher pace.
* **Defending.** It covers the player's line for at most 2 s, and only against a car within 14 m.

### Rails (`race_director.gd`)

A rival that cannot be seen leaves the physics world. That means more than 185 m from the camera,
or more than 55 m away and outside the view. It also has to be more than 50 m of road from your
car, upright, on the road, and not being rescued. The director disables its node
(`PROCESS_MODE_DISABLED`), which removes the rigid body from Jolt and stops its tyre model,
network and sound. It then moves the car along its lane at the speed its own pace limiter allows,
braking for corners as the bot would. It keeps 9 m to a car ahead in the same lane and passes a
slower one on the free side. A ground ray every 6 ticks keeps the car on the surface.

Rail speed is calibrated. On the road a car laps about 4% faster than its pace limit suggests,
because the limit is measured along the centre line and the car's line gains on it. Run straight,
the rails would leave a sleeping car about 4% slow (Hanami: 1.035–1.041 at every pace). When a
rival first goes on rails, the director computes the lap its limit profile would take. This is an
O(samples) pass that agrees with a time-stepped simulation to 0.1 s. It then scales the rail speed
by that lap over the stage's calibrated flying lap for the car's model and pace.

No car goes on rails while another car is level with it (within about 7 m of road). If a car on
rails finds itself level with another at matched pace (speeds within 1.5 m/s), it settles the pair
by the running order: 4% quicker if it is ahead, 4% slower if it is behind. Both cars agree on who
is ahead, so the pair always separates; a clearly faster car just passes. Without this, two cars at
the same pace could run level and swap places in the running order hundreds of times a race. One
CI race logged 1,161 swaps between two rivals on rails side by side, 3 m apart, both speeding up
because each counted itself "level". After the fix: 40 swaps with rails on, 28 without.

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

## Measured (CI, GitHub runner, headless, Hanami, 2 laps)

Run 45971512590:

| | Upstream / rails off | This build |
|---|---|---|
| Network, one decision | 654 µs (`DrivePolicy`) | 74 µs (8.8×), worst logit difference 2.9e-6, same options 400/400 |
| Bot script cost (race probe COST) | 760 + 72 µs per decision | 148 + 81 µs |
| Cars' own physics per tick, full race | 1276 µs | 918 µs (−28%) with rails |
| Whole physics tick | 2915 µs | 2414 µs (−17%) |
| Rival ticks on rails | 0 | 34% (49 sleeps, 48 wakes, none went wrong) |
| Rescues / flips | 0 / 0 | 0 / 0 |
| Overtakes / contacts (race probe, no player) | 18 / 2 | 21 / 8 (worst a 1.55 m/s nudge) |

Headless, the camera follows the player's car closely. On a phone the ratio of rails is similar.
Each rival on rails saves its full physics step (about 0.7 ms per 120 Hz tick on the Adreno 730
tablet). Physics ran up to 4 ticks per frame there, so a race at 30–40 fps gets back several ms
per frame when the field spreads out.
