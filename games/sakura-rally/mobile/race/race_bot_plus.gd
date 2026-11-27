extends RaceBot
## Sakura Rally: a RaceBot that races for the place (Game-development-3rd-party, MIT; RaceBot and
## the shipped driver are Summer Engine's, MIT).
##
## Main gives every rival one of these instead of a plain RaceBot (prepare.py changes that one
## line of scripts/main.gd). The network, the lanes, the pace limiter and the rescue are
## RaceBot's; what changes is how the bot uses them in traffic:
##
##   attack   following closer (ATTACK_FOLLOW_S instead of 0.35 s of its speed), lifting at a time
##            to collision of ATTACK_LIFT_TTC_S instead of 1.5 s and braking at
##            ATTACK_BRAKE_TTC_S instead of 1.0 s; passing a car that is PASS_MARGIN_PLUS m/s
##            slower (was 1.0) seen PASS_LOOK_PLUS m ahead (was 40); with a car close ahead its
##            pace limiter brakes later for the corners (ATTACK_DECEL instead of 4 m/s²).
##   draft    in the slipstream of a car ahead in its lane on a fast stretch, the pace limit
##            rises by DRAFT_BONUS (the slipstream tow), so it can pull alongside on the straight.
##   defend   the player's car close behind is not waved through any more: the bot moves its lane
##            to cover the player's line once, for up to DEFEND_MAX_S (never towards a car
##            alongside, RaceBot's rule), then lets it try. Bots still make room for each other,
##            but only for one YIELD_MARGIN m/s faster.
##   pace     the lap time it is set to is never slower than the campaign's (gold x pace), and
##            when the player has a record on the stage (time trial, or a race lap kept by
##            race_director.gd) the field is spread around it: pole (slowest) SLOWEST_K x the
##            player's lap, the last rival on the grid FASTEST_K x. A faster player meets faster
##            rivals.
##   network  the shipped driver evaluated in 4x4 blocks (fast_policy.gd): the same decisions at
##            about a quarter of the script time.

const FastPolicy := preload("res://mobile/race/fast_policy.gd")
const Director := preload("res://mobile/race/race_director.gd")

const ATTACK_FOLLOW_S := 0.25
const ATTACK_LIFT_TTC_S := 1.15
const ATTACK_BRAKE_TTC_S := 0.8
const ATTACK_BRAKE_NEED := 3.6
## A car within this many metres ahead (and ATTACK_SIDE_M across) makes it attack.
const ATTACK_LOOK_M := 30.0
const ATTACK_SIDE_M := 3.0
const ATTACK_DECEL := 5.0
const PASS_MARGIN_PLUS := 0.5
const PASS_LOOK_PLUS := 50.0
const YIELD_MARGIN := 1.5
## Defending against the player's car from DEFEND_FROM_M to DEFEND_TO_M behind (bumper to
## bumper), above DEFEND_MIN_MPS.
const DEFEND_FROM_M := 1.0
const DEFEND_TO_M := 22.0
const DEFEND_MIN_MPS := 8.0
## One move: it covers the player's line for at most DEFEND_MAX_S, then not again until the
## player's car has been out of range for DEFEND_RESET_S.
const DEFEND_MAX_S := 3.0
const DEFEND_RESET_S := 4.0
const DRAFT_FROM_M := 5.0
const DRAFT_TO_M := 30.0
const DRAFT_SIDE_M := 1.6
const DRAFT_MIN_MPS := 18.0
const DRAFT_BONUS := 0.05
## A time-trial lap includes the standing start; a flying lap is about this much quicker.
const STANDING_START_S := 3.0
const SLOWEST_K := 1.10
const FASTEST_K := 0.97

## The network in blocks, shared by every bot (one decision runs at a time).
static var _fast: DrivePolicy

## The pace before the director's catch-up (race_director.gd scales `pace` from it).
var base_pace: float = 1.0
## Read-only, from the last decision.
var attacking: bool = false
var drafting: bool = false
var defending: bool = false
## Counters (CI): decisions spent attacking, drafting, defending.
var attack_count: int = 0
var draft_count: int = 0
var defend_count: int = 0
var _defend_s: float = 0.0
var _clear_s: float = 0.0


func _ready() -> void:
	if policy == null:
		if _fast == null:
			var plain := DrivePolicy.load_file(DRIVER)
			if plain != null:
				var f := FastPolicy.new()
				f.adopt(plain)
				_fast = f
		policy = _fast
	super._ready()
	add_to_group(&"race_bot_plus")
	_adapt_pace()
	base_pace = pace


## Sets `pace` from the player's own lap when that asks for a faster field (see the header).
func _adapt_pace() -> void:
	if car == null or track == null or field.size() < 2:
		return
	var map_id := str(Game.map_id)
	var lap := minf(float(Game.best_time(map_id)) - STANDING_START_S, Director.race_best_lap(map_id))
	if not is_finite(lap) or lap < 30.0:
		return
	var rank := field.find(car) - 1 # field: the player's car, then the grid from pole
	var n := field.size() - 1
	if rank < 0 or n < 1:
		return
	var k := lerpf(SLOWEST_K, FASTEST_K, float(rank) / float(maxi(n - 1, 1)))
	var car_id := "hayate" if str(car.scene_file_path).contains("hayate") else "sakura"
	pace = maxf(pace, RaceBot.pace_for_lap(map_id, lap * k, car_id))


## RaceBot._race with the cars seen first, so this decision's attack and slipstream count.
func _race(step: float) -> void:
	var pos := car.global_position
	var i := sense.hint
	var s := track.abs_s(i, pos)
	var lat := track.lateral(i, pos)
	var v := car.linear_velocity.dot(track.forward(i))
	var lat_v := car.linear_velocity.dot(track.right(i))
	_see(s, pos)
	_battle(lat, v)
	var limit := _limit(s)
	_pedals(lat, lat_v, v)
	_pace(v, limit)
	_steer_lane(lat, v, limit, _room(i), step)
	_rescue(s, lat, i, step)


func _battle(lat: float, v: float) -> void:
	attacking = false
	drafting = false
	for o in _near:
		var ds: float = o[0]
		if ds <= 0.0:
			continue
		var side := absf(float(o[1]) - lat)
		if ds < ATTACK_LOOK_M and side < ATTACK_SIDE_M:
			attacking = true
		if ds > DRAFT_FROM_M and ds < DRAFT_TO_M and side < DRAFT_SIDE_M and v > DRAFT_MIN_MPS:
			drafting = true
	attack_count += int(attacking)
	draft_count += int(drafting)


## RaceBot._limit, braking at ATTACK_DECEL while attacking.
func _limit(s: float) -> float:
	if _ref.is_empty():
		return INF
	var decel := ATTACK_DECEL if attacking else PACE_DECEL
	var lowest := INF
	var k := _ref_index(s)
	var n := _ref.size()
	for m in int(PACE_LOOK_M / _ref_step) + 1:
		var v := pace * (_ref[wrapi(k + m, 0, n)] if track.closed else _ref[mini(k + m, n - 1)])
		lowest = minf(lowest, sqrt(v * v + 2.0 * decel * m * _ref_step))
	return lowest


func _pace(v: float, limit: float) -> void:
	super._pace(v, limit * (1.0 + DRAFT_BONUS) if drafting else limit)


## RaceBot._pedals with the attack distances.
func _pedals(lat: float, lat_v: float, v: float) -> void:
	var thr := hands.throttle_target
	var brk := hands.brake_target
	_blocked = false
	for o in _near:
		var ds: float = o[0]
		if ds <= 0.0:
			continue
		var gap := ds - CAR_LENGTH
		var closing: float = v - float(o[2])
		var ttc := gap / closing if closing > 0.1 else INF
		var horizon := clampf(ttc, 0.0, 1.0)
		var o_lat: float = o[1]
		var o_lat_v: float = o[3]
		var shift := lat_v * horizon
		if absf(_lane_target - lat) > 0.5:
			shift = clampf(_lane_target - lat, -LANE_RATE * horizon, LANE_RATE * horizon)
		if absf(o_lat - lat) > CAR_WIDTH and absf(o_lat + o_lat_v * horizon - lat - shift) > CAR_WIDTH:
			continue
		var follow := FOLLOW_M + ATTACK_FOLLOW_S * maxf(v, 0.0)
		if gap < follow + 4.0 and v < STUCK_MPS * 2.0:
			_blocked = true
		if gap < follow or ttc < ATTACK_LIFT_TTC_S:
			thr = 0.0
		if closing > 0.1:
			var need := closing * closing / (2.0 * maxf(gap - 1.0, 0.3))
			if need > ATTACK_BRAKE_NEED or ttc < ATTACK_BRAKE_TTC_S:
				brk = maxf(brk, clampf(need / BRAKE_DECEL, 0.2, 1.0))
	held = thr < hands.throttle_target or brk > hands.brake_target
	hands.throttle_target = thr
	hands.brake_target = brk


func _is_player(other: Variant) -> bool:
	return other != null and is_instance_valid(other) and other == Game.player_car


## RaceBot._steer_lane, passing more eagerly, defending against the player and yielding to a
## faster bot only.
func _steer_lane(lat: float, v: float, limit: float, room: float, step: float) -> void:
	var cur := sense.lane
	var target := 0.0
	defending = false
	if room > 0.3:
		var want := minf(limit, v + 10.0)
		var pass_car: Array = []
		var behind: Array = []
		var threat: Array = []
		for o in _near:
			var ds: float = o[0]
			var o_v: float = o[2]
			if ds > 0.0 and ds < PASS_LOOK_PLUS and absf(float(o[5]) - _lane_target) < SIDE_CLEAR \
					and (o_v < want - PASS_MARGIN_PLUS or v - o_v > PASS_MARGIN_PLUS) \
					and (pass_car.is_empty() or ds < float(pass_car[0])):
				pass_car = o
			elif _is_player(o[4]) and ds < -CAR_LENGTH - DEFEND_FROM_M and ds > -CAR_LENGTH - DEFEND_TO_M \
					and v > DEFEND_MIN_MPS:
				threat = o
			elif ds <= CAR_LENGTH and ds > -SEE_BEHIND_M and (o_v > v + YIELD_MARGIN or ds > -CAR_LENGTH) \
					and (behind.is_empty() or absf(ds) < absf(float(behind[0]))):
				behind = o
		if not pass_car.is_empty():
			target = _pass_side(pass_car, room)
		elif not behind.is_empty() and float(behind[0]) > -CAR_LENGTH:
			# a car alongside: make room on the side away from it (RaceBot's rule)
			var o_lane: float = behind[5]
			var side := -room if o_lane > cur else room
			target = side if _side_clear(side, -SEE_BEHIND_M, CAR_LENGTH, behind[4]) else _lane_target
		elif not threat.is_empty() and _defend_s < DEFEND_MAX_S:
			# the player's car behind: cover its line (one move, see DEFEND_MAX_S)
			target = clampf(float(threat[1]), -room, room)
			defending = true
		elif not behind.is_empty():
			var o_lane: float = behind[5]
			var side := room if cur >= 0.0 else -room
			if absf(o_lane - cur) > 0.5:
				side = -room if o_lane > cur else room
			target = side if _side_clear(side, -SEE_BEHIND_M, CAR_LENGTH, behind[4]) else _lane_target
		elif _lane_target != 0.0 and not _side_clear(0.0, -CAR_LENGTH - 2.0, PASS_LOOK_PLUS, null):
			target = _lane_target # home is taken for now
		if threat.is_empty():
			_clear_s += step
			if _clear_s > DEFEND_RESET_S:
				_defend_s = 0.0
		else:
			_clear_s = 0.0
			_defend_s += step
	for o in _near:
		var o_lane: float = o[5]
		if absf(float(o[0])) < CAR_LENGTH + 1.0 and signf(o_lane - cur) == signf(target - cur) \
				and absf(o_lane - cur) < SIDE_CLEAR + 0.5:
			target = cur # never towards a car alongside
			defending = false
			break
	defend_count += int(defending)
	_lane_target = target
	var next := move_toward(cur, clampf(target, -room, room), LANE_RATE * step)
	if absf(next - lat) > LANE_KEEP and absf(next - lat) > absf(cur - lat):
		next = cur
	sense.lane = next
