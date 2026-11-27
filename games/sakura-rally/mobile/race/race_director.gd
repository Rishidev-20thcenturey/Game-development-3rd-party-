extends Node
## Sakura Rally: race director (Game-development-3rd-party, MIT).
##
## mobile.gd adds one as a child of every RaceField (Game.MODE_RACE). It never changes how a car
## drives while you can see it; it changes what a race costs and how close it stays:
##
##   phases   The six rivals' networks decide in six different physics ticks spread evenly over
##            DriveHands.DECISION_TICKS (Main gives them ticks 0-5 of 12, so at 30 fps one frame
##            ran four decisions and the next none: an uneven frame time).
##
##   rails    A rival that nobody can see - more than SLEEP_FAR_M from the camera, or more than
##            SLEEP_HIDDEN_M away and outside the camera's view - and that is not near the
##            player's car on the road, leaves the physics world: its node is disabled (no
##            rigid body, tyre model, network, visuals or engine sound) and the director moves it
##            along its lane at the speed its own pace limit allows (RaceBot._limit(): pace x the
##            driver's recorded speed, braking early for the corners), following any car ahead in
##            its lane and changing lane to pass it. Before it can be seen or touched again
##            (WAKE_* below, with hysteresis) it rejoins the physics world where it is, at its
##            speed, in a gear that fits, and its network decides at once. On a phone a car's
##            physics costs about 0.7 ms per tick and there are 120 ticks a second, so every
##            rival on rails gives back several ms per frame. A rival on rails still counts for
##            the race (RaceField reads its position), is seen by the other bots and passes
##            through nothing it could hit: cars on rails keep RAIL_FOLLOW_M from the car ahead.
##
##   rubber   A light catch-up: a rival far ahead of the player on the road eases its pace by up
##            to BAND_AHEAD, one far behind raises it by up to BAND_BEHIND (never above the
##            driver's own speed x BAND_CAP). Nothing changes within BAND_FROM_M.
##
## It also keeps the player's best race lap per stage (user://mobile_race.cfg), which
## race_bot_plus.gd uses with the time-trial record to set the rivals' pace.

const RACE_CFG := "user://mobile_race.cfg"

## Rails: distances from the camera (m). Asleep beyond SLEEP_FAR_M, or beyond SLEEP_HIDDEN_M when
## outside the view; awake again within WAKE_VIEW_M in view, or within WAKE_NEAR_M anywhere.
const SLEEP_FAR_M := 185.0
const WAKE_VIEW_M := 160.0
const SLEEP_HIDDEN_M := 55.0
const WAKE_NEAR_M := 42.0
## Within this road distance of the player's car a rival always has full physics (contact).
const PLAYER_SLEEP_GAP_M := 50.0
const PLAYER_WAKE_GAP_M := 40.0
## Least time between two changes of one car, and the time the body takes to line up with the
## road after falling asleep (unseen anyway).
const MIN_STATE_S := 1.0
const BLEND_S := 0.5
## Rails motion: acceleration and braking (m/s²), the gap kept to a car ahead in the same lane
## (m, bumper to bumper) and lateral clearance that counts as the same lane (m).
const RAIL_ACCEL := 3.2
const RAIL_DECEL := 7.0
const RAIL_FOLLOW_M := 9.0
const RAIL_LOOK_M := 45.0
const RAIL_SAME_LANE_M := 2.4
const RAIL_LANE_RATE := 1.2
const CAR_LENGTH := 4.3
## Two cars level in different lanes (within this many metres of road): no car goes on rails
## beside another, and a car on rails beside one settles it, ALONGSIDE_K faster when level or
## ahead, as much slower when behind (two cars at the same average pace would otherwise run level
## and swap places in the running order tick after tick).
const ALONGSIDE_M := CAR_LENGTH + 3.0
const ALONGSIDE_K := 0.04
## Ground height under a car on rails: a ray every GROUND_TICKS ticks, smoothed.
const GROUND_TICKS := 6
## How often sleep / wake is decided (ticks).
const DECIDE_TICKS := 4
## Rubber band (m of road and pace factors).
const BAND_FROM_M := 60.0
const BAND_FULL_M := 400.0
const BAND_AHEAD := 0.05
const BAND_BEHIND := 0.08
const BAND_TICKS := 30
## The catch-up never takes a rival above this pace (unless it was set faster).
const BAND_CAP := 0.95

## Off: no rival ever goes on rails (CI compares both).
static var rails_default := true

## One rival.
class Rival:
	var car: Car
	var bot: Node
	var entrant: RaceField.Entrant
	var base_pace: float = 1.0
	var asleep: bool = false
	var since: float = 0.0
	var s: float = 0.0
	var lat: float = 0.0
	var lat_target: float = 0.0
	var v: float = 0.0
	var dy: float = 0.0
	var dy_target: float = 0.0
	var blend: float = 1.0
	var from_basis: Basis = Basis.IDENTITY
	var sleeps: int = 0
	var wakes: int = 0
	var rail_ticks: int = 0
	var woke_at: float = -1.0
	## Rail speed x this: the rail lap at its pace matches the lap the car drives on the road
	## (0 = not computed yet; see _rail_scale()).
	var rail_scale: float = 0.0


var rails_enabled: bool = rails_default
var race: RaceField
var main: Node
var track: Track
var rivals: Array[Rival] = []
## Totals for the meter and CI.
var awake_ticks: int = 0
var rail_ticks: int = 0
var sleeps: int = 0
var wakes: int = 0
var _tick: int = 0
var _clock: float = 0.0
var _ready_done := false


func _ready() -> void:
	name = "RaceDirector"
	add_to_group(&"race_director")
	process_physics_priority = 100
	race = get_parent() as RaceField
	if race == null:
		queue_free()
		return
	main = race.get_parent()
	_setup.call_deferred()


func _setup() -> void:
	if race == null or not is_instance_valid(race) or race.track == null or main == null:
		return
	track = race.track
	var cars: Array = main.get("rivals") if main.get("rivals") != null else []
	var n := cars.size()
	for k in n:
		var car := cars[k] as Car
		if car == null:
			continue
		var r := Rival.new()
		r.car = car
		r.bot = car.get_node_or_null(^"RaceBot")
		for e: RaceField.Entrant in race.entrants:
			if e.car == car:
				r.entrant = e
		if r.bot != null:
			r.bot.set(&"phase", (k * DriveHands.DECISION_TICKS) / maxi(n, 1))
			var bp: Variant = r.bot.get(&"base_pace")
			r.base_pace = float(bp) if bp != null else float(r.bot.get(&"pace"))
		rivals.append(r)
	if not Game.race_finished.is_connected(_on_race_finished):
		Game.race_finished.connect(_on_race_finished)
	race.car_finished.connect(_on_car_finished)
	_ready_done = true


func _exit_tree() -> void:
	if Game.race_finished.is_connected(_on_race_finished):
		Game.race_finished.disconnect(_on_race_finished)


## Rivals on rails right now.
func asleep_count() -> int:
	var n := 0
	for r in rivals:
		n += int(r.asleep)
	return n


func _physics_process(delta: float) -> void:
	if not _ready_done or not is_instance_valid(race):
		return
	_tick += 1
	_clock += delta
	var cam := get_viewport().get_camera_3d()
	var player: Car = race.player.car if race.player != null and is_instance_valid(race.player.car) else null
	var decide := _tick % DECIDE_TICKS == 0
	for r in rivals:
		if not is_instance_valid(r.car) or not r.car.is_inside_tree():
			continue
		r.since += delta
		if r.asleep:
			_rail_step(r, delta)
			r.rail_ticks += 1
			rail_ticks += 1
			if decide and _must_wake(r, cam, player):
				_wake(r)
		else:
			awake_ticks += 1
			if decide and rails_enabled and _may_sleep(r, cam, player):
				_sleep(r)
	if _tick % BAND_TICKS == 0:
		_band()


# ---------------------------------------------------------------- rails: when

func _bot_ok(r: Rival) -> bool:
	if r.bot == null or not is_instance_valid(r.bot) or not r.bot.is_inside_tree():
		return false
	var ref: Variant = r.bot.get(&"_ref")
	if not (ref is PackedFloat32Array):
		return false
	var arr: PackedFloat32Array = ref
	return not arr.is_empty()


func _road_gap(r: Rival, player: Car) -> float:
	if player == null or race.player == null or r.entrant == null:
		return INF
	return absf(r.entrant.dist - race.player.dist)


func _may_sleep(r: Rival, cam: Camera3D, player: Car) -> bool:
	if cam == null or not race.running or r.since < MIN_STATE_S or not _bot_ok(r):
		return false
	if r.entrant != null and r.entrant.finished:
		return false
	var car := r.car
	if car.launch_hold or car.global_basis.y.y < 0.8 or car.linear_velocity.length() < 4.0:
		return false
	if float(r.bot.get(&"_trouble")) > 0.0:
		return false
	var i := track.nearest(car.global_position, int(r.bot.get(&"sense").hint), 24)
	if absf(track.lateral(i, car.global_position)) > track.half_width(i):
		return false
	if _road_gap(r, player) < PLAYER_SLEEP_GAP_M:
		return false
	if r.entrant != null:
		for o in race.entrants:
			if o != r.entrant and not o.finished and absf(o.dist - r.entrant.dist) < ALONGSIDE_M:
				return false
	var d := cam.global_position.distance_to(car.global_position)
	if d > SLEEP_FAR_M:
		return true
	return d > SLEEP_HIDDEN_M and not _in_view(cam, car.global_position)


func _must_wake(r: Rival, cam: Camera3D, player: Car) -> bool:
	if not rails_enabled or cam == null or not race.running or not _bot_ok(r):
		return true
	if r.entrant != null and r.entrant.finished:
		return true
	if r.since < MIN_STATE_S * 0.5:
		return false
	if _road_gap(r, player) < PLAYER_WAKE_GAP_M:
		return true
	var p := r.car.global_position
	var d := cam.global_position.distance_to(p)
	if d < WAKE_NEAR_M:
		return true
	if d < WAKE_VIEW_M and _in_view(cam, p):
		return true
	# one second ahead along the road, in case it is about to come round a corner into view
	var ahead := track.position_at_abs(r.s + r.v, r.lat)
	return cam.global_position.distance_to(ahead) < WAKE_VIEW_M and _in_view(cam, ahead)


func _in_view(cam: Camera3D, p: Vector3) -> bool:
	return cam.is_position_in_frustum(p + Vector3.UP * 0.7) or cam.is_position_in_frustum(p + Vector3.UP * 1.6)


# ---------------------------------------------------------------- rails: in and out

func _sleep(r: Rival) -> void:
	var car := r.car
	var bot := r.bot
	var pos := car.global_position
	var i := track.nearest(pos, int(bot.get(&"sense").hint), 24)
	r.s = track.abs_s(i, pos)
	r.lat = track.lateral(i, pos)
	r.v = maxf(car.linear_velocity.dot(track.forward(i)), 0.0)
	var room := _room(i)
	r.lat_target = clampf(float(bot.get(&"lane")), -room, room)
	r.lat = clampf(r.lat, -track.half_width(i) + 1.0, track.half_width(i) - 1.0)
	r.dy = pos.y - track.position_at_abs(r.s, r.lat).y
	r.dy_target = r.dy
	r.from_basis = car.global_basis.orthonormalized()
	r.blend = 0.0
	for w: WheelState in car.wheels:
		w.contact = false # the wheel effects stop throwing dust from a car that is not there
		w.slip = 0.0
	if r.rail_scale == 0.0:
		r.rail_scale = _rail_scale(r)
	car.process_mode = Node.PROCESS_MODE_DISABLED
	r.asleep = true
	r.since = 0.0
	r.sleeps += 1
	sleeps += 1


func _wake(r: Rival) -> void:
	var car := r.car
	var bot := r.bot
	car.process_mode = Node.PROCESS_MODE_INHERIT
	r.asleep = false
	r.since = 0.0
	r.wakes += 1
	wakes += 1
	r.woke_at = _clock
	var fwd := -car.global_basis.z
	car.linear_velocity = fwd * r.v
	car.angular_velocity = Vector3.ZERO
	var rest: float = car.bump_travel
	var lengths: PackedFloat32Array = car.get(&"_prev_length")
	for k in 4:
		var w: WheelState = car.wheels[k]
		w.spin_speed = r.v / Car.WHEEL_RADIUS
		w.suspension_length = rest
		w.slip = 0.0
		w.slip_long = 0.0
		w.slip_lat = 0.0
		w.slide_speed = 0.0
		lengths[k] = rest
	car.set(&"_prev_length", lengths)
	car.set(&"_last_lin", car.linear_velocity)
	car.set(&"_last_ang", Vector3.ZERO)
	car.set(&"_guard", 0.0)
	car.set(&"_stuck_time", 0.0)
	car.airborne_time = 0.0
	# a gear that fits the speed, as the automatic box would have it
	var dt := car.drivetrain
	var g := 1
	while g < dt.top_gear() and dt.rpm_for_speed(r.v, g, Car.WHEEL_RADIUS) > dt.max_rpm * 0.8:
		g += 1
	var rpm := clampf(dt.rpm_for_speed(r.v, g, Car.WHEEL_RADIUS), dt.idle_rpm, dt.max_rpm)
	dt.gear = g
	dt.is_shifting = false
	dt.rpm = rpm
	dt.set(&"_omega_e", rpm * Drivetrain.RPM_TO_RADS)
	dt.set(&"_v_prev", NAN)
	dt.set(&"_shift_timer", 0.0)
	dt.set(&"_shift_cooldown", 0.3)
	car.gear = g
	car.rpm = rpm
	if r.entrant != null and r.entrant.finished:
		return
	if bot == null or not is_instance_valid(bot) or not bot.is_inside_tree():
		return
	# the bot sees the road anew from here and decides at once
	var sense: DriveSense = bot.get(&"sense")
	var room := _room(track.index_at_abs(r.s))
	sense.reset(r.s)
	sense.lane = clampf(r.lat, -room, room)
	bot.set(&"_lane_target", r.lat_target)
	bot.set(&"_last_pos", car.global_position)
	bot.set(&"_last_s", NAN)
	bot.set(&"_trouble", 0.0)
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	bot.call(&"decide", tick)
	bot.call(&"_race", tick * DriveHands.DECISION_TICKS)
	# the inputs follow at once, not a tick late
	var hands: DriveHands = bot.get(&"hands")
	if hands != null:
		hands.apply(car, tick)


# ---------------------------------------------------------------- rails: motion

func _room(i: int) -> float:
	var room := INF
	for k in range(-5, 26):
		room = minf(room, track.half_width(i + k))
	return maxf(room - 3.5, 0.0)


func _rail_step(r: Rival, delta: float) -> void:
	var car := r.car
	var limit := INF
	if _bot_ok(r):
		limit = float(r.bot.call(&"_limit", r.s))
	if limit == INF:
		limit = r.v
	else:
		limit *= r.rail_scale if r.rail_scale > 0.0 else 1.0
	# the car ahead in its lane: keep RAIL_FOLLOW_M, pass on the free side when it is slower
	var cap := INF
	var blocker_lat := NAN
	var settle := 1.0
	for o in race.entrants:
		if o.car == car or not is_instance_valid(o.car):
			continue
		var op := o.car.global_position
		var ds := track.abs_s(o.idx, op) - r.s
		if track.closed:
			ds = wrapf(ds, -track.length * 0.5, track.length * 0.5)
		if absf(ds) < ALONGSIDE_M and not o.finished:
			settle = 1.0 - ALONGSIDE_K if ds > 0.5 else 1.0 + ALONGSIDE_K
		if ds <= 0.0 or ds > RAIL_LOOK_M:
			continue
		var olat := track.lateral(o.idx, op)
		if absf(olat - r.lat) > RAIL_SAME_LANE_M:
			continue
		var ov := maxf(o.car.linear_velocity.dot(track.forward(o.idx)), 0.0)
		var c := ov + (ds - CAR_LENGTH - RAIL_FOLLOW_M) * 0.8
		if c < cap:
			cap = c
			blocker_lat = olat
	var i := track.index_at_abs(r.s)
	var room := _room(i)
	if not is_nan(blocker_lat) and cap < limit - 1.0 and room > 0.3:
		var side := -room if blocker_lat >= 0.0 else room
		if _rail_side_clear(r, side) and absf(side - blocker_lat) >= RAIL_SAME_LANE_M:
			r.lat_target = side
		elif _rail_side_clear(r, -side) and absf(-side - blocker_lat) >= RAIL_SAME_LANE_M:
			r.lat_target = -side
	elif is_nan(blocker_lat) and absf(r.lat_target) > 0.01 and _rail_side_clear(r, 0.0):
		r.lat_target = 0.0
	r.lat_target = clampf(r.lat_target, -room, room)
	var target := maxf(minf(limit * settle, cap), 0.0)
	r.v = minf(target, r.v + RAIL_ACCEL * delta) if r.v < target else maxf(target, r.v - RAIL_DECEL * delta)
	r.s += r.v * delta
	r.s = fposmod(r.s, track.length) if track.closed else clampf(r.s, track.first_s, track.last_s)
	r.lat = move_toward(r.lat, r.lat_target, RAIL_LANE_RATE * delta)
	# pose: along the road's slope and camber at the lane
	var p := track.position_at_abs(r.s, r.lat)
	var fwd := track.position_at_abs(r.s + 2.0, r.lat) - track.position_at_abs(r.s - 2.0, r.lat)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else -car.global_basis.z
	var across := track.position_at_abs(r.s, r.lat + 1.0) - track.position_at_abs(r.s, r.lat - 1.0)
	var up := across.normalized().cross(fwd).normalized()
	if up.y < 0.5:
		up = Vector3.UP
	var basis := Basis.looking_at(fwd, up)
	if r.rail_ticks % GROUND_TICKS == 0:
		var space := car.get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 3.0, p + Vector3.DOWN * 4.0, Car.WORLD_LAYER, [car.get_rid()])
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			r.dy_target = (hit["position"] as Vector3).y - p.y
	r.dy = lerpf(r.dy, r.dy_target, 1.0 - exp(-delta / 0.15))
	if r.blend < 1.0:
		r.blend = minf(r.blend + delta / BLEND_S, 1.0)
		basis = r.from_basis.slerp(basis, smoothstep(0.0, 1.0, r.blend))
	car.global_transform = Transform3D(basis, p + Vector3.UP * (r.dy + 0.005))
	car.linear_velocity = fwd * r.v
	car.angular_velocity = Vector3.ZERO
	car.speed_kmh = r.v * 3.6
	if r.bot != null and is_instance_valid(r.bot):
		var sense: DriveSense = r.bot.get(&"sense")
		sense.lane = r.lat_target
		sense.hint = i


func _rail_side_clear(r: Rival, side: float) -> bool:
	for o in race.entrants:
		if o.car == r.car or not is_instance_valid(o.car):
			continue
		var op := o.car.global_position
		var ds := track.abs_s(o.idx, op) - r.s
		if track.closed:
			ds = wrapf(ds, -track.length * 0.5, track.length * 0.5)
		if ds > -CAR_LENGTH - 6.0 and ds < RAIL_LOOK_M and absf(track.lateral(o.idx, op) - side) < RAIL_SAME_LANE_M:
			return false
	return true


## How much faster than its pace limit the car really laps: the stage's calibration (the flying
## lap a car of its model drives at its pace, assets/ai/pace/<route>.json) over the lap the rails
## would take: the limit profile driven with RAIL_ACCEL (O(samples), when it first goes on rails).
## On Hanami that is about 1.04 at every pace: on the road the car's line gains on the centre
## line the limit is measured along. 1.0 without a calibration.
func _rail_scale(r: Rival) -> float:
	var ref: PackedFloat32Array = r.bot.get(&"_ref")
	var step := float(r.bot.get(&"_ref_step"))
	var n := ref.size()
	if n < 10 or not track.closed:
		return 1.0
	var car_id := str(r.entrant.info.get("car_id", "sakura")) if r.entrant != null else "sakura"
	var laps: Dictionary = RaceBot._pace_file(str(Game.map_id)).get("laps", {})
	var rows: Array = laps.get(car_id, laps.get("sakura", []))
	if rows.size() < 2:
		return 1.0
	var pace := r.base_pace
	var flying := NAN
	for k in range(1, rows.size()):
		var a: Dictionary = rows[k - 1]
		var b: Dictionary = rows[k]
		if pace <= float(b["pace"]) or k == rows.size() - 1:
			var t := clampf((pace - float(a["pace"])) / maxf(float(b["pace"]) - float(a["pace"]), 1e-3), 0.0, 1.0)
			flying = lerpf(float(a["flying"]), float(b["flying"]), t)
			break
	var decel := 4.0 # RaceBot.PACE_DECEL
	var lim := PackedFloat32Array()
	lim.resize(n)
	for k in n:
		lim[k] = pace * ref[k]
	for pass_ in 2:
		for k in range(n - 1, -1, -1):
			var nxt := lim[(k + 1) % n]
			lim[k] = minf(lim[k], sqrt(nxt * nxt + 2.0 * decel * step))
	var v := lim[0]
	var lap := 0.0
	for pass_ in 2:
		lap = 0.0
		for k in n:
			v = minf(lim[k], sqrt(v * v + 2.0 * RAIL_ACCEL * step))
			lap += step / maxf(v, 1.0)
	if not is_finite(flying) or flying <= 0.0:
		return 1.0
	return clampf(lap / flying, 0.9, 1.1)


# ---------------------------------------------------------------- catch-up, records

func _band() -> void:
	var on := race.running and race.player != null and not race.player.finished
	for r in rivals:
		if r.bot == null or not is_instance_valid(r.bot):
			continue
		var k := 1.0
		if on and r.entrant != null and not r.entrant.finished:
			var gap := r.entrant.dist - race.player.dist
			k = 1.0 - BAND_AHEAD * smoothstep(BAND_FROM_M, BAND_FULL_M, gap) \
					+ BAND_BEHIND * smoothstep(BAND_FROM_M, BAND_FULL_M, -gap)
		var pace := r.base_pace * k
		if k > 1.0:
			pace = minf(pace, maxf(r.base_pace, BAND_CAP))
		r.bot.set(&"pace", pace)


## A rival took the flag: if it was on rails, it rejoins the physics world for its ArrivalStop
## (Main connected first, so the stop is already on the car).
func _on_car_finished(car: Car, _position: int) -> void:
	for r in rivals:
		if r.car == car and r.asleep:
			_wake(r)


func _on_race_finished(result: Dictionary) -> void:
	if bool(result.get("ai_drove", false)):
		return
	var lap := float(result.get("best_lap", INF))
	var map_id := str(result.get("map_id", Game.map_id))
	if is_finite(lap) and lap > 10.0 and lap < race_best_lap(map_id):
		var cfg := ConfigFile.new()
		cfg.load(RACE_CFG)
		cfg.set_value("best_lap", map_id, lap)
		cfg.save(RACE_CFG)


## The player's best race lap on `map_id` (s), INF when none.
static func race_best_lap(map_id: String) -> float:
	var cfg := ConfigFile.new()
	if cfg.load(RACE_CFG) != OK:
		return INF
	return float(cfg.get_value("best_lap", map_id, INF))
