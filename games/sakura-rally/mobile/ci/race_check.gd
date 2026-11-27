extends SceneTree
## CI check for race mode (mobile/race: race_director.gd, race_bot_plus.gd, fast_policy.gd),
## headless:
##
##   godot --headless --fixed-fps 60 --path . -s res://mobile/ci/race_check.gd -- [map=hanami]
##       [player=1.1] [seconds=330] [runs=off,on]
##
## 1. The batched network against DrivePolicy: logits on the policy's test vector and on random
##    observations, the chosen options, and the script time of one evaluation.
## 2. The real race mode (Main's grid, RaceField, the rivals' bots) once per entry of `runs`:
##    "off" with no rival ever on rails, "on" as the game ships. A plain RaceBot drives the
##    player's car at `player` x gold. Per run: the time a physics tick takes (whole engine,
##    headless), the cars' own physics time per tick, the share of rival ticks on rails, every
##    car woken from rails watched for three seconds (upright, on the road, moving), rescues,
##    flips, places changed, finishers and their times, and how often the bots attacked,
##    drafted and defended. Prints RACE / POLICY lines, CHECK lines and a SUMMARY.

## Loaded once the autoloads are up (a -s script compiles before them, and these name Game).
var FastPolicy: GDScript
var Director: GDScript
const PLUS_PATH := "res://mobile/race/race_bot_plus.gd"

var opts := {"map": "hanami", "player": "1.1", "seconds": "330", "runs": "off,on"}
var game: Node
var main: Node
var failures: Array[String] = []
var checks := 0
var meter: Meter


## Counts every physics tick: the cars' own physics time and which rivals are awake.
class Meter extends Node:
	var cars: Array = []
	var rivals: Array = []
	var ticks: int = 0
	var car_usec: int = 0
	var awake: int = 0
	var rails: int = 0

	func _physics_process(_delta: float) -> void:
		ticks += 1
		for c: Variant in cars:
			if is_instance_valid(c) and (c as Node).can_process():
				car_usec += int(c.get(&"step_usec"))
		for c: Variant in rivals:
			if is_instance_valid(c):
				if (c as Node).can_process():
					awake += 1
				else:
					rails += 1


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	game = root.get_node("Game")
	game.set_setting("quality", "low")
	game.set_setting("transmission", "auto")
	meter = Meter.new()
	meter.name = "RaceCheckMeter"
	meter.process_physics_priority = 1000
	root.add_child(meter)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 120.0)
	FastPolicy = load("res://mobile/race/fast_policy.gd")
	Director = load("res://mobile/race/race_director.gd")
	_policy_checks()
	var results := {}
	for mode in str(opts["runs"]).split(",", false):
		results[mode] = await _race(mode == "on")
		game.request_menu()
		await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 60.0)
		await _frames(10)
	if results.has("off") and results.has("on") and not results["off"].is_empty() and not results["on"].is_empty():
		var a: Dictionary = results["off"]
		var b: Dictionary = results["on"]
		print("RACE compare: physics tick %.0f -> %.0f us (%.0f%%), cars' physics %.0f -> %.0f us per tick (%.0f%%), rails %.0f%% of rival ticks" % [
				a["tick_us"], b["tick_us"], 100.0 * (b["tick_us"] / maxf(a["tick_us"], 1.0) - 1.0),
				a["car_us"], b["car_us"], 100.0 * (b["car_us"] / maxf(a["car_us"], 1.0) - 1.0), 100.0 * b["rails_share"]])
		_check(b["car_us"] < a["car_us"], "rails: the cars' physics costs less per tick (%.0f vs %.0f us)" % [b["car_us"], a["car_us"]])
		_check(int(b["flips"]) <= int(a["flips"]) + 1, "rails: no more flips than without (%d vs %d)" % [b["flips"], a["flips"]])
		_check(int(b.get("order_flips", 0)) <= 3 * int(a.get("order_flips", 0)) + 60,
				"rails: the running order does not churn (%d order flips vs %d without)" % [b.get("order_flips", 0), a.get("order_flips", 0)])
	_finish()


# ---------------------------------------------------------------- the network

func _policy_checks() -> void:
	var plain := DrivePolicy.load_file("res://assets/ai/driver.json")
	_check(plain != null, "driver policy loads")
	if plain == null:
		return
	var fast: DrivePolicy = FastPolicy.new()
	fast.call(&"adopt", plain)
	var worst := 0.0
	var test: Array = plain.meta.get("test_obs", [])
	if test.size() == plain.obs_size:
		var obs := PackedFloat32Array(test)
		var a := plain.logits(obs)
		var b := fast.logits(obs)
		for i in a.size():
			worst = maxf(worst, absf(a[i] - b[i]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var n := 400
	var agree := 0
	var samples: Array[PackedFloat32Array] = []
	for k in n:
		var obs := PackedFloat32Array()
		obs.resize(plain.obs_size)
		for i in plain.obs_size:
			obs[i] = rng.randf_range(-1.2, 1.2)
		samples.append(obs)
		var a := plain.logits(obs)
		var b := fast.logits(obs)
		for i in a.size():
			worst = maxf(worst, absf(a[i] - b[i]))
		agree += int(plain.act(obs) == fast.act(obs))
	var t0 := Time.get_ticks_usec()
	for obs in samples:
		plain.logits(obs)
	var plain_us := (Time.get_ticks_usec() - t0) / float(n)
	t0 = Time.get_ticks_usec()
	for obs in samples:
		fast.logits(obs)
	var fast_us := (Time.get_ticks_usec() - t0) / float(n)
	print("POLICY batched network: worst logit difference %s, same options %d/%d, %.0f us -> %.0f us per evaluation (%.1fx)" % [
			String.num_scientific(worst), agree, n, plain_us, fast_us, plain_us / maxf(fast_us, 0.001)])
	_check(worst < 1e-3, "batched network: logits match DrivePolicy (worst %s)" % String.num_scientific(worst))
	_check(agree >= n - 2, "batched network: the same options (%d/%d)" % [agree, n])
	_check(fast_us < plain_us * 0.6, "batched network: faster (%.0f vs %.0f us)" % [fast_us, plain_us])


# ---------------------------------------------------------------- a race

func _race(rails: bool) -> Dictionary:
	var tag := "on" if rails else "off"
	Director.set(&"rails_default", rails)
	# both runs start from the same rival paces: no race lap kept from an earlier run
	DirAccess.remove_absolute(ProjectSettings.globalize_path(str(Director.get(&"RACE_CFG"))))
	game.set(&"ai_drove", true)
	var map_id := str(opts["map"])
	game.request_start(map_id, game.MODE_RACE)
	await _until(func() -> bool: return int(game.state) == int(game.State.INTRO) and main.race != null, 90.0)
	await _frames(5)
	var race: RaceField = main.race
	var car: Car = game.player_car
	var rivals: Array = main.rivals
	if race == null or car == null or rivals.is_empty():
		_check(false, "race %s: the grid was built" % tag)
		return {}
	var director: Node = race.get_node_or_null(^"RaceDirector")
	var plus := 0
	var phases := {}
	for r: Car in rivals:
		var bot := r.get_node_or_null(^"RaceBot")
		plus += int(bot != null and (bot.get_script() as Script).resource_path == PLUS_PATH)
		if bot != null:
			phases[int(bot.get(&"phase"))] = true
	_check(director != null and bool(director.get(&"rails_enabled")) == rails, "race %s: a race director, rails %s" % [tag, tag])
	_check(plus == rivals.size(), "race %s: every rival races with race_bot_plus.gd (%d/%d)" % [tag, plus, rivals.size()])
	_check(phases.size() == rivals.size(), "race %s: the rivals decide in %d different ticks (%s)" % [tag, phases.size(), phases.keys()])
	var paces := PackedStringArray()
	for r: Car in rivals:
		var bot := r.get_node_or_null(^"RaceBot")
		paces.append("%.3f" % float(bot.get(&"pace")) if bot != null else "?")
	print("RACE %s: rival paces from pole %s" % [tag, ", ".join(paces)])
	var lo := INF
	var hi := 0.0
	for r: Car in rivals:
		var bot := r.get_node_or_null(^"RaceBot")
		if bot != null:
			lo = minf(lo, float(bot.get(&"pace")))
			hi = maxf(hi, float(bot.get(&"pace")))
	_check(lo >= 0.749 and hi >= 0.879 and hi <= 0.951, "race %s: the field runs at 0.75-0.88 of the driver's speed (%.3f-%.3f)" % [tag, lo, hi])
	# a plain RaceBot drives the player's car (the bots defend against it as against you)
	var gold := float((game.get_map(map_id)["medals"] as Dictionary)["gold"])
	var driver := RaceBot.new()
	driver.name = "RaceBot"
	driver.track = main.map.track
	driver.pace = RaceBot.pace_for_lap(map_id, gold * float(opts["player"]), str(game.current_car()["id"]))
	driver.field = (rivals[0].get_node(^"RaceBot") as RaceBot).field
	driver.phase = DriveHands.DECISION_TICKS - 1
	car.controlled_by_player = false
	car.add_child(driver)
	game.set(&"ai_drove", true) # sets no record (and race_director.gd keeps no race lap)
	await _until(func() -> bool: return int(game.state) == int(game.State.RACING), 60.0)
	meter.cars = [car] + rivals
	meter.rivals = rivals.duplicate()
	var tick0 := meter.ticks
	var car0 := meter.car_usec
	var awake0 := meter.awake
	var rails0 := meter.rails
	var wall0 := Time.get_ticks_usec()
	var track: Track = main.map.track
	var limit_ticks := int(float(opts["seconds"]) * Engine.physics_ticks_per_second)
	var was_asleep := {}
	var watch: Array[Dictionary] = []
	var bad := 0
	var woken := 0
	var flips := 0
	var rolled := {}
	var rescues := {}
	var battle := {"attack": {}, "draft": {}, "defend": {}}
	var gains := 0
	var flip_last := {}
	var flip_rec := {}
	var last_pos := {}
	var hints := {}
	while meter.ticks - tick0 < limit_ticks:
		await physics_frame
		var t := (meter.ticks - tick0) / float(Engine.physics_ticks_per_second)
		var all_done := true
		for e in race.entrants:
			all_done = all_done and e.finished
			if not e.player:
				var lp: int = last_pos.get(e.car.get_instance_id(), e.position)
				if e.position < lp and not e.finished:
					gains += lp - e.position
				last_pos[e.car.get_instance_id()] = e.position
		# order flips per pair (who, with or without a car on rails, involving the player)
		var ents: Array = race.entrants
		for a in ents.size():
			for b in range(a + 1, ents.size()):
				var ea: RaceField.Entrant = ents[a]
				var eb: RaceField.Entrant = ents[b]
				if ea.finished or eb.finished:
					continue
				var key := "%s/%s" % [str(ea.info.get("name", "?")), str(eb.info.get("name", "?"))]
				var ahead := ea.position < eb.position
				if flip_last.has(key) and bool(flip_last[key]) != ahead:
					var rec: Array = flip_rec.get(key, [0, 0, ea.player or eb.player, 0.0])
					rec[0] += 1
					rec[1] += int(not ea.car.can_process() or not eb.car.can_process())
					rec[3] += absf(ea.car.global_position.distance_to(eb.car.global_position))
					flip_rec[key] = rec
				flip_last[key] = ahead
		if all_done:
			break
		for r: Car in rivals:
			if not is_instance_valid(r):
				continue
			var id := r.get_instance_id()
			var asleep := not r.can_process()
			if bool(was_asleep.get(id, false)) and not asleep:
				woken += 1
				hints.erase(id) # it moved on rails: a full search, not one round the old spot
				watch.append({"car": r, "until": t + 3.0, "from": t, "ok": true, "why": ""})
			was_asleep[id] = asleep
			var is_rolled := r.global_basis.y.y < 0.2
			if is_rolled and not bool(rolled.get(id, false)):
				flips += 1
			rolled[id] = is_rolled
			var bot := r.get_node_or_null(^"RaceBot")
			if bot != null:
				rescues[id] = int(bot.get(&"rescues"))
				for key in ["attack", "draft", "defend"]:
					(battle[key] as Dictionary)[id] = int(bot.get(StringName(key + "_count")))
		for w in watch:
			if not bool(w["ok"]) or t > float(w["until"]):
				continue
			var c: Car = w["car"]
			if not is_instance_valid(c):
				continue
			var finished := false
			for e in race.entrants:
				if e.car == c:
					finished = e.finished
			var i := track.nearest(c.global_position, int(hints.get(c.get_instance_id(), -1)), 30)
			hints[c.get_instance_id()] = i
			var off := absf(track.lateral(i, c.global_position)) - track.half_width(i) - track.verge
			if c.global_basis.y.y < 0.5:
				w["ok"] = false
				w["why"] = "tilted"
			elif off > 2.0:
				w["ok"] = false
				w["why"] = "%.1f m off the road" % off
			elif not finished and t - float(w["from"]) > 1.5 and c.can_process() and c.linear_velocity.length() < 4.0:
				w["ok"] = false
				w["why"] = "slow (%.1f m/s)" % c.linear_velocity.length()
			if not bool(w["ok"]):
				bad += 1
				print("RACE %s: woken car %s went wrong %.1f s after waking: %s" % [tag, c.name, t - float(w["from"]), w["why"]])
	var ticks := maxi(meter.ticks - tick0, 1)
	var wall_us := (Time.get_ticks_usec() - wall0) / float(ticks)
	var car_us := (meter.car_usec - car0) / float(ticks)
	var rival_ticks := maxi((meter.awake - awake0) + (meter.rails - rails0), 1)
	var rails_share := (meter.rails - rails0) / float(rival_ticks)
	var finished_n := 0
	var rows := PackedStringArray()
	for e in race.order:
		finished_n += int(e.finished and not e.player)
		rows.append("%d %s %s" % [e.position, str(e.info.get("name", "?")), game.format_time(e.time) if e.finished else "dnf"])
	var sum := func(d: Dictionary) -> int:
		var s := 0
		for v: int in d.values():
			s += v
		return s
	var sleeps := int(director.get(&"sleeps")) if director != null and is_instance_valid(director) else 0
	var res := {"tick_us": wall_us, "car_us": car_us, "rails_share": rails_share, "flips": flips, "bad": bad,
			"woken": woken, "finished": finished_n, "rescues": sum.call(rescues), "gains": gains}
	print("RACE %s: %.1f s, %d ticks: physics tick %.0f us (whole engine, headless), cars' physics %.0f us per tick, rails %.0f%% of rival ticks, %d sleeps, %d wakes (%d went wrong), rescues %d, flips %d, places gained on track %d, attack %d / draft %d / defend %d decisions" % [
			tag, ticks / float(Engine.physics_ticks_per_second), ticks, wall_us, car_us, 100.0 * rails_share, sleeps, woken, bad,
			res["rescues"], flips, gains, sum.call(battle["attack"]), sum.call(battle["draft"]), sum.call(battle["defend"])])
	print("RACE %s: classification %s" % [tag, " | ".join(rows)])
	var keys := flip_rec.keys()
	keys.sort_custom(func(x: String, y: String) -> bool: return int(flip_rec[x][0]) > int(flip_rec[y][0]))
	var player_flips := 0
	var total_flips := 0
	for k: String in keys:
		total_flips += int(flip_rec[k][0])
		player_flips += int(flip_rec[k][0]) if bool(flip_rec[k][2]) else 0
	var top := PackedStringArray()
	for k: String in keys.slice(0, 4):
		var rec: Array = flip_rec[k]
		top.append("%s %d flips (%d with one on rails, %.1f m apart on average)" % [k, rec[0], rec[1], float(rec[3]) / maxf(float(rec[0]), 1.0)])
	print("RACE %s: order flips %d, %d involving the player; most: %s" % [tag, total_flips, player_flips, " | ".join(top)])
	res["order_flips"] = total_flips
	if rails and director != null and is_instance_valid(director):
		var scales := PackedStringArray()
		for rv: Variant in director.get(&"rivals"):
			scales.append("%.3f" % float(rv.get(&"rail_scale")))
		print("RACE %s: rail speed scale per rival (rail lap / calibrated lap, 0 = never slept) %s" % [tag, ", ".join(scales)])
	_check(finished_n == rivals.size(), "race %s: every rival finished (%d/%d)" % [tag, finished_n, rivals.size()])
	_check(bad == 0, "race %s: every car woken from rails drove on (%d of %d went wrong)" % [tag, bad, woken])
	if rails:
		_check(sleeps > 0 and woken > 0, "race %s: rivals went on rails and came back (%d sleeps, %d wakes)" % [tag, sleeps, woken])
	else:
		_check(sleeps == 0, "race %s: no rival on rails (%d)" % [tag, sleeps])
	meter.cars = []
	meter.rivals = []
	return res


# ---------------------------------------------------------------- helpers

func _check(ok: bool, what: String) -> void:
	checks += 1
	print("CHECK %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _until(cond: Callable, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > timeout * 1000.0:
			print("TIMEOUT after %.0f s (state=%s)" % [timeout, (game.State as Dictionary).find_key(game.state)])
			return
		await process_frame


func _finish() -> void:
	print("SUMMARY race_check: %d checks, %d failed" % [checks, failures.size()])
	for f in failures:
		print("FAIL ", f)
	quit(1 if not failures.is_empty() else 0)
