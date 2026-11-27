extends SceneTree
## CI check for the touch / Android layer. It runs the real game with the Mobile autoload in
## touch mode at a 20:9 phone-shaped window and drives it only with InputEventScreenTouch /
## InputEventScreenDrag events through Input.parse_input_event, the same path the Android
## touchscreen takes. It also exercises the Back-button handler.
## Prints CHECK lines and a summary, and exits non-zero on failures. When rendered (not
## --headless) it also saves screenshots to `out`.
##
##   godot --headless --path . -s res://mobile/ci/mobile_check.gd -- --touch
##   xvfb-run godot --rendering-method mobile --path . -s res://mobile/ci/mobile_check.gd -- --touch out=/tmp/shots

var opts := {"out": "/tmp/mobile_shots", "map": "hanami", "w": "1600", "h": "720"}
var main: Node
var game: Node
var mobile: Node
var controls: Node
var failures: Array[String] = []
var t0 := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["out"])
	root.size = Vector2i(int(opts["w"]), int(opts["h"]))
	game = root.get_node("Game")
	mobile = root.get_node("Mobile")
	game.set_setting("quality", "low")
	game.set_setting("camera", "chase")
	game.set_setting("transmission", "auto")
	t0 = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	# NaN watch over the whole run: logs the first frame the camera or a car is not finite
	_NAN_WATCH = GDScript.new()
	_NAN_WATCH.source_code = _NAN_WATCH_SRC
	_NAN_WATCH.reload()
	_watch = _nan_watch()
	_check(mobile != null and bool(mobile.touch_enabled), "Mobile autoload in touch mode")
	controls = mobile.controls
	_check(controls != null, "touch controls created")
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 90.0)
	await _seconds(2.5)
	_check(not bool(controls.active), "touch controls hidden on the title hub")
	_check(mobile._on_title_hub(), "Back on the title hub would quit (handler sees the hub)")
	_check(mobile.hints_hidden(), "keyboard hint strip hidden on touch screens")
	await shot("01_title")

	# ------------------------------------------------------------ title hub, driven by taps
	var title: Node = main.ui.title
	await _tap_control(title._time_attack_item)
	await _seconds(1.5)
	_check(str(title.view) == "time_attack", "tapping Time Attack opens its page (view=%s)" % title.view)
	await shot("01b_time_attack")
	var rb: String = mobile.handle_back()
	await _seconds(1.5)
	_check(str(title.view) == "title", "Back from Time Attack returns to the hub (%s, view=%s)" % [rb, title.view])

	# ------------------------------------------------------------ free roam, driven by touch
	game.request_start(opts["map"], game.MODE_FREE_ROAM)
	await _until(func() -> bool: return int(game.state) == int(game.State.FREE_ROAM), 90.0)
	await _seconds(1.5)
	_check(int(game.state) == int(game.State.FREE_ROAM), "free roam reached")
	_check(bool(controls.active), "touch controls shown while driving")
	_check(bool(mobile._hud_done), "HUD tachometer moved to the bottom centre")
	var car: Node = game.player_car
	_check(car != null, "player car exists")
	if car == null:
		_finish()
		return

	_touch(0, "throttle", true)
	await _seconds(0.2)
	_check(controls.is_held("throttle") and Input.is_action_pressed(&"throttle"), "GAS touch presses throttle")
	await _seconds(2.8)
	_check(float(car.speed_kmh) > 30.0, "car accelerates under touch throttle (%.0f km/h)" % float(car.speed_kmh))

	var fwd0: Vector3 = car.global_transform.basis.z
	_touch(1, "right", true)
	await _seconds(0.15)
	_check(Input.is_action_pressed(&"steer_right"), "▶ touch presses steer_right")
	await shot("02_drive_touch")
	await _seconds(1.2)
	var fwd1: Vector3 = car.global_transform.basis.z
	var yaw := rad_to_deg(Vector2(fwd0.x, fwd0.z).angle_to(Vector2(fwd1.x, fwd1.z)))
	_check(absf(yaw) > 4.0, "car turns while ▶ is held (yaw %.1f°)" % yaw)

	# slide the steering finger across to ◀ without lifting
	_drag(1, "left")
	await _seconds(0.15)
	_check(Input.is_action_pressed(&"steer_left") and not Input.is_action_pressed(&"steer_right"),
			"sliding the finger to ◀ swaps steer_right for steer_left")
	_touch(1, "left", false)
	# slide the pedal finger from GAS to BRAKE
	_drag(0, "brake")
	await _seconds(0.15)
	_check(Input.is_action_pressed(&"brake") and not Input.is_action_pressed(&"throttle"),
			"sliding GAS → BRAKE swaps the pedals")
	await _seconds(1.0)
	_touch(0, "brake", false)
	await _seconds(0.15)
	_check(not Input.is_action_pressed(&"brake") and not Input.is_action_pressed(&"steer_left"),
			"lifting every finger releases every action")

	# handbrake held with two fingers at once
	_touch(2, "throttle", true)
	_touch(3, "handbrake", true)
	await _seconds(0.3)
	_check(Input.is_action_pressed(&"handbrake") and Input.is_action_pressed(&"throttle"), "multi-touch: GAS + HANDBRAKE together")
	_touch(3, "handbrake", false)
	_touch(2, "throttle", false)

	# camera button
	var cam_before := str(main.chase.mode)
	_touch(4, "camera", true)
	await _frames(4)
	_touch(4, "camera", false)
	await _frames(2)
	_check(str(main.chase.mode) != cam_before, "camera button cycles %s -> %s" % [cam_before, main.chase.mode])
	main.chase.set_mode("chase")

	# pause button, then Back resumes
	_touch(5, "pause", true)
	await _frames(3)
	_touch(5, "pause", false)
	await _seconds(0.5)
	_check(bool(game.paused), "pause button pauses")
	_check(not bool(controls.active), "touch controls hidden while paused")
	await shot("03_pause")
	var r: String = mobile.handle_back()
	await _seconds(0.5)
	_check(r == "resume" and not bool(game.paused), "Back on the pause menu resumes (%s)" % r)

	# Back while driving pauses
	await _seconds(0.3)
	r = mobile.handle_back()
	await _seconds(0.4)
	_check(r == "pause" and bool(game.paused), "Back while driving pauses (%s)" % r)
	mobile.handle_back()
	await _seconds(0.5)
	_check(not bool(game.paused), "Back again resumes")

	# app sent to the background mid-drive pauses
	_touch(6, "throttle", true)
	await _seconds(0.2)
	mobile._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _seconds(0.3)
	_check(bool(game.paused) and not Input.is_action_pressed(&"throttle"), "background: drive paused, controls released")
	game.set_paused(false)
	await _seconds(0.3)

	# performance meter + lab
	await _perf_lab_checks()

	# manual gearbox shows the shift buttons
	game.set_setting("transmission", "manual")
	var ids: Array = controls._visible_buttons().map(func(b: Dictionary) -> String: return b["id"])
	_check(ids.has("shift_up") and ids.has("shift_down"), "manual gearbox shows ▲ ▼")
	_touch(7, "throttle", true)
	await _seconds(1.5)
	var g0 := int(car.gear)
	_touch(8, "shift_up", true)
	await _frames(4)
	_touch(8, "shift_up", false)
	await _seconds(0.8)
	_check(int(car.gear) > g0, "▲ shifts up (gear %d -> %d)" % [g0, int(car.gear)])
	await shot("04_manual")
	_touch(7, "throttle", false)
	game.set_setting("transmission", "auto")

	# ------------------------------------------------------------ time trial grid + countdown
	game.request_start(opts["map"], game.MODE_TIME_TRIAL)
	await _until(_on_grid, 90.0)
	await _seconds(0.6)
	await shot("05_countdown")
	await _until(func() -> bool: return int(game.state) == int(game.State.RACING), 30.0)
	_touch(0, "throttle", true)
	await _seconds(4.0)
	await shot("06_stage")
	_touch(0, "throttle", false)
	_check(int(game.state) == int(game.State.RACING) and bool(controls.active), "time trial racing with touch controls")
	await _census_checks()

	# ------------------------------------------------------------ back to the menu
	game.request_menu()
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 60.0)
	await _seconds(1.0)
	_check(not bool(controls.active), "controls hidden again on the menu")

	# ------------------------------------------------------------ race mode, from the menu
	await _race_checks()
	game.request_menu()
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 60.0)
	await _seconds(1.0)

	# ------------------------------------------------------------ campaign started by a tap
	await _until(func() -> bool: return not bool(main.ui.title._switching), 20.0)
	await _seconds(1.0)
	await _tap_control(main.ui.title._campaign_item)
	await _until(_left_menu, 90.0)
	_check(_left_menu(), "tapping New journey starts the campaign (state=%s)" % (game.State as Dictionary).find_key(game.state))
	await _seconds(3.0)
	await shot("07_campaign")
	_check(str(_watch.get_meta(&"first", "")) == "", "camera and cars never NaN over the run %s" % str(_watch.get_meta(&"first", "")))
	_finish()


func _perf_lab_checks() -> void:
	var perf: Node = mobile.get("perf")
	_check(perf != null, "performance lab created")
	if perf == null:
		return
	_check(not bool(perf._meter.visible), "perf meter hidden by default off-phone (clean screenshots)")
	perf.meter_on = true
	await _seconds(1.5)
	var st: Dictionary = perf.stats
	_check(float(st.get("fps", 0.0)) > 0.0 and str(perf._meter.text).contains("fps") and str(perf._meter.text).contains("GPU"),
			"perf meter shows fps, CPU and GPU time (%s)" % str(perf._meter.text).replace("\n", " | "))
	_log("physics catch-up limit: %d steps per frame" % Engine.max_physics_steps_per_frame)
	await _tap_control(perf._meter)
	await _seconds(0.4)
	_check(bool(game.paused) and bool(perf._panel.visible), "tapping the meter pauses and opens the lab")
	var win := root
	await _tap_control(perf._rows["scale"])
	await _tap_control(perf._rows["scale"])
	await _frames(3)
	_check(is_equal_approx(win.scaling_3d_scale, 0.85), "lab: 3D resolution 85%% (scale %.2f)" % win.scaling_3d_scale)
	await _tap_control(perf._rows["ink"])
	await _tap_control(perf._rows["shadows"])
	await _frames(3)
	var quad: Node3D = main.post.ink_quad
	var sun: DirectionalLight3D = main.map.atmosphere.sun
	_check(not quad.visible, "lab: ink lines off")
	_check(not sun.shadow_enabled, "lab: sun shadows off")
	await _tap_control(perf._rows["cap"])
	_check(Engine.max_fps == 120, "lab: frame-rate cap 120 (max_fps %d)" % Engine.max_fps)
	await shot("08_perf_lab")
	var rep: String = perf.copy_report()
	_check(rep.contains("fps") and rep.contains("switches:"), "lab: report copied")
	# restore everything
	for i in 6:
		perf._on_row("cap")
	for i in 3:
		perf._on_row("scale")
	perf._on_row("ink")
	perf._on_row("shadows")
	await _frames(3)
	_check(Engine.max_fps == 0 and quad.visible and sun.shadow_enabled and int(perf.scale_i) == 0,
			"lab: switches restore the normal look (scale %.2f)" % win.scaling_3d_scale)
	# GPU profile: every step runs and everything is put back afterwards
	game.set_paused(false)
	await _seconds(0.3)
	var cam_mask := root.get_camera_3d().cull_mask
	var scale_before := win.scaling_3d_scale
	perf.profile_time_scale = 0.1
	await perf.run_profile()
	await _frames(2)
	var rows: Array = perf.profile_rows
	_log("profile:\n" + str(perf.profile_text()))
	_check(rows.size() == perf.PROFILE_STEPS.size(), "GPU profile ran all %d steps (%d)" % [perf.PROFILE_STEPS.size(), rows.size()])
	var props: Node3D = main.map.get_node("Props")
	var terrain: Node3D = main.map.get_node("Terrain")
	_check(props.visible and terrain.visible and quad.visible and sun.shadow_enabled
			and root.get_camera_3d().cull_mask == cam_mask and is_equal_approx(win.scaling_3d_scale, scale_before)
			and bool(main.ui.visible) and bool(controls.visible) and perf._outline_cache.is_empty()
			and not Input.is_action_pressed(&"handbrake") and Engine.max_fps == 0
			and bool(perf.occlusion_on) and bool(perf.ink_fast) and root.use_occlusion_culling,
			"GPU profile puts everything back (scale %.2f, mask %d)" % [win.scaling_3d_scale, root.get_camera_3d().cull_mask])
	_check(bool(perf._results.visible) and bool(perf._panel.visible), "GPU profile shows its table in the lab")
	await shot("09_profile")
	perf.lab_open = false
	perf.meter_on = false
	game.set_paused(false)
	await _seconds(0.3)

	# phone tuning (on by default on phones; forced on here)
	perf.tuning_enabled = true
	game.set_setting("quality", "high")
	await _frames(6)
	var sun2: DirectionalLight3D = main.map.atmosphere.sun
	_check(root.msaa_3d == Viewport.MSAA_2X and is_equal_approx(sun2.directional_shadow_split_1, 0.065)
			and absf(sun2.directional_shadow_max_distance - 320.05) < 0.01,
			"phone tuning on High: MSAA 2x, tighter first cascade (msaa %d, split %.3f, dist %.2f)" % [
			root.msaa_3d, sun2.directional_shadow_split_1, sun2.directional_shadow_max_distance])
	game.set_setting("quality", "low")
	await _frames(6)
	_check(is_equal_approx(sun2.directional_shadow_split_1, 0.1) and absf(sun2.directional_shadow_max_distance - 160.05) < 0.01
			and root.msaa_3d == Viewport.MSAA_DISABLED,
			"phone tuning follows the switch back to Low (split %.3f, dist %.2f)" % [
			sun2.directional_shadow_split_1, sun2.directional_shadow_max_distance])
	_check(is_equal_approx(root.mesh_lod_threshold, perf.lod_threshold_for(root.scaling_3d_scale)) and root.mesh_lod_threshold > 1.0,
			"phone tuning: mesh LOD threshold = one rendered pixel (%.2f at %.0f%%)" % [root.mesh_lod_threshold, root.scaling_3d_scale * 100.0])
	_check(is_equal_approx(perf.lod_threshold_for(1.0), 1.0) and is_equal_approx(perf.lod_threshold_for(0.5), 2.0),
			"LOD threshold: 1 px at 100%, 2 px at 50%")
	perf.tuning_enabled = false
	root.mesh_lod_threshold = 1.0
	var pst: Dictionary = perf.stats
	_log("meter: " + str(perf._meter_text()))
	_check(pst.has("jolt_ms") and pst.has("physics_scripts_ms") and int(pst.get("cars", 0)) >= 1,
			"meter splits the physics tick (cars %d, tick %.2f, scripts %.2f, cars %.2f ms)" % [
			int(pst.get("cars", 0)), float(pst.get("physics_ms", 0.0)), float(pst.get("physics_scripts_ms", 0.0)), float(pst.get("car_ms", 0.0))])
	# automatic resolution decisions (60 fps target = 16.67 ms)
	_check(perf.drs_decide(0.71, 30.0, 0.45, 0.71, 16.67) < 0.71, "auto resolution steps down when the GPU is over budget (%.2f)" % perf.drs_decide(0.71, 30.0, 0.45, 0.71, 16.67))
	_check(perf.drs_decide(0.5, 5.0, 0.45, 0.71, 16.67) > 0.5, "auto resolution steps back up with headroom")
	_check(perf.drs_decide(0.6, 13.0, 0.45, 0.71, 16.67) == 0.6, "auto resolution holds inside the comfort band")
	_check(perf.drs_decide(0.46, 60.0, 0.45, 0.71, 16.67) == 0.45, "auto resolution never goes below its floor")
	await _seconds(0.4)
	_check(not bool(game.paused) and not bool(perf._panel.visible), "lab closed, drive resumed")


## Load census: draws and triangles of the main and shadow passes on every preset, what each
## group of objects adds, and an inventory of the heaviest objects near the camera (what casts
## the shadow triangles). Time is frozen so every measurement sees the same frame. Render counts
## are only real when rendering; the inventory is computed from the scene and works headless.
func _census_checks() -> void:
	var perf: Node = mobile.get("perf")
	var rendering := DisplayServer.get_name() != "headless"
	Input.action_press(&"handbrake")
	await _seconds(3.0)
	Engine.time_scale = 0.0
	await _frames(3)
	for q: String in ["high", "medium", "low"]:
		game.set_setting("quality", q)
		await _frames(6)
		var c: Dictionary = await _census(perf)
		_log("CENSUS q=%-6s main %4d draws %5dk tris | shadows %4d draws %5dk tris" % [
				q, c["draws"], roundi(c["tris"] / 1000.0), c["shadow_draws"], roundi(c["shadow_tris"] / 1000.0)])
	if rendering:
		await _exact_lever_checks(perf)
	game.set_setting("quality", "high")
	await _frames(6)
	var cam := root.get_camera_3d()
	var shadow_reach: float = main.map.atmosphere.sun.directional_shadow_max_distance
	_log("CENSUS inventory, High, camera %s, shadow distance %.0f m" % [str(cam.global_position.round()), shadow_reach])
	for row: Array in _inventory(cam, shadow_reach + 30.0, true).slice(0, 18):
		_log("CENSUS shadow caster %-34s %7dk tris in %4d objects (nearest %4.0f m)%s" % [row[0], roundi(row[1] / 1000.0), row[2], row[3], row[4]])
	for row: Array in _inventory(cam, 1400.0, false).slice(0, 18):
		_log("CENSUS main object   %-34s %7dk tris in %4d objects (nearest %4.0f m)%s" % [row[0], roundi(row[1] / 1000.0), row[2], row[3], row[4]])
	if rendering:
		var groups := {"props": [main.map.get_node("Props")], "terrain": [main.map.get_node("Terrain")], "cars": _cars()}
		var base: Dictionary = await _census(perf)
		for g: String in groups:
			for n: Node3D in groups[g]:
				n.visible = false
			await _frames(2)
			var c: Dictionary = await _census(perf)
			for n: Node3D in groups[g]:
				n.visible = true
			_log("CENSUS q=high %-8s main -%4d draws -%5dk tris | shadows -%4d draws -%5dk tris" % [g,
					int(base["draws"]) - int(c["draws"]), roundi((int(base["tris"]) - int(c["tris"])) / 1000.0),
					int(base["shadow_draws"]) - int(c["shadow_draws"]), roundi((int(base["shadow_tris"]) - int(c["shadow_tris"])) / 1000.0)])
		await _frames(2)
		# what drawing far trees as flat pictures could save at most: hide prop chunks beyond R
		var props_root: Node3D = main.map.get_node("Props")
		var here := cam.global_position
		for reach: float in [250.0, 400.0, 600.0]:
			var hidden: Array[GeometryInstance3D] = []
			for ch in props_root.get_children():
				var gi := ch as GeometryInstance3D
				if gi == null or not gi.visible:
					continue
				var bx: AABB = gi.global_transform * gi.get_aabb()
				if (here.clamp(bx.position, bx.end) - here).length() > reach:
					gi.visible = false
					hidden.append(gi)
			await _frames(2)
			var cf: Dictionary = await _census(perf)
			for gi in hidden:
				gi.visible = true
			_log("CENSUS q=high props beyond %3.0f m (%4d chunks): main -%4d draws -%5dk tris | shadows -%4d draws -%5dk tris" % [
					reach, hidden.size(), int(base["draws"]) - int(cf["draws"]), roundi((int(base["tris"]) - int(cf["tris"])) / 1000.0),
					int(base["shadow_draws"]) - int(cf["shadow_draws"]), roundi((int(base["shadow_tris"]) - int(cf["shadow_tris"])) / 1000.0)])
		await _frames(2)
	_check(true, "load census logged")
	Engine.time_scale = 1.0
	Input.action_release(&"handbrake")
	game.set_setting("quality", "low")
	await _frames(3)


## Race mode (mobile/race): the director joins the race, every rival races with
## race_bot_plus.gd, the grid with six rivals (shot), then 24 s (9 s when rendering) of racing with a RaceBot on the
## player's car: the cars' physics per tick and how many rivals are on rails (the perf meter
## shows it), and a shot of the pack.
func _race_checks() -> void:
	game.request_start(opts["map"], game.MODE_RACE)
	var watch := _watch
	await _until(func() -> bool: return main.race != null and _on_grid(), 90.0)
	await _seconds(0.6)
	var race: Node = main.race
	var rivals: Array = main.rivals
	var director := race.get_node_or_null(^"RaceDirector") if race != null else null
	var plus := 0
	for r: Node in rivals:
		var bot := r.get_node_or_null(^"RaceBot")
		plus += int(bot != null and str(bot.get_script().resource_path).ends_with("race_bot_plus.gd"))
	_check(director != null, "race: the race director joined the race")
	_check(rivals.size() == 6 and plus == rivals.size(), "race: six rivals racing with race_bot_plus.gd (%d/%d)" % [plus, rivals.size()])
	await shot("11_race_grid")
	var car: Car = game.player_car
	var driver := RaceBot.new()
	driver.name = "RaceBot"
	driver.track = main.map.track
	driver.pace = 0.95
	driver.field = (rivals[0].get_node(^"RaceBot") as RaceBot).field if not rivals.is_empty() else []
	driver.phase = 11
	car.controlled_by_player = false
	car.add_child(driver)
	game.set(&"ai_drove", true)
	await _until(func() -> bool: return int(game.state) == int(game.State.RACING), 30.0)
	var perf: Node = mobile.get("perf")
	if perf != null:
		perf.meter_on = true
	var most_asleep := 0
	var car_ms := 0.0
	var n := 0
	# software rendering draws a seven-car race slowly: a shorter look when rendering
	var t_end: float = 24.0 if DisplayServer.get_name() == "headless" else 9.0
	var t := 0.0
	while t < t_end:
		await _seconds(1.0)
		t += 1.0
		if director != null and is_instance_valid(director):
			most_asleep = maxi(most_asleep, int(director.call(&"asleep_count")))
		if perf != null:
			var st: Dictionary = perf.stats
			car_ms += float(st.get("car_ms", 0.0))
			n += 1
		var cam3 := root.get_camera_3d()
		_log("RACE t=%2.0f state=%s camera %s (%s) at %s, fov %.0f" % [t, (game.State as Dictionary).find_key(game.state),
				cam3.name if cam3 != null else "none", cam3.get_class() if cam3 != null else "", str(cam3.global_position.round()) if cam3 != null else "",
				cam3.fov if cam3 != null else 0.0])
		if t == minf(12.0, t_end - 3.0):
			await shot("12_race_pack")
	var meter := str(perf._meter.text).replace("\n", " | ") if perf != null else ""
	_log("RACE %d s: most rivals on rails at once %d, sleeps %d, wakes %d, cars' physics %.2f ms per tick (mean of the meter), meter: %s" % [
			int(t_end), most_asleep, int(director.get(&"sleeps")) if director != null else -1,
			int(director.get(&"wakes")) if director != null else -1, car_ms / maxf(n, 1.0), meter])
	_check(meter.contains("on rails"), "race: the perf meter counts the rivals on rails")
	var placed := 0
	for e: Variant in race.entrants:
		placed += int(int(e.position) > 0)
	_check(placed == 7, "race: seven cars classified (%d)" % placed)
	await shot("13_race_meter")
	if perf != null:
		perf.meter_on = false
	if is_instance_valid(driver):
		driver.queue_free()
	_check(str(watch.get_meta(&"first", "")) == "", "camera and cars never NaN so far %s" % str(watch.get_meta(&"first", "")))


## A node that checks every frame (through the race) that the current camera and every car have
## finite positions, and logs the first frame one does not: which node, its class, the state.
func _nan_watch() -> Node:
	var w := Node.new()
	w.name = "NanWatch"
	w.process_mode = Node.PROCESS_MODE_ALWAYS
	w.set_script(_NAN_WATCH)
	root.add_child(w)
	w.set_meta(&"check", self)
	return w


const _NAN_WATCH_SRC := """extends Node
var frames := 0
func _process(_d: float) -> void:
	if get_meta(&"stop", false):
		queue_free()
		return
	frames += 1
	var bad := ""
	var cam := get_viewport().get_camera_3d()
	if cam != null and not cam.global_transform.origin.is_finite():
		bad = "camera %s (%s, parent %s)" % [cam.name, cam.get_class(), cam.get_parent().name]
	var g := get_node(^"/root/Game")
	var cars: Array = get_tree().get_nodes_in_group(&"race_rival")
	if g.player_car != null:
		cars.append(g.player_car)
	for c in cars:
		if is_instance_valid(c) and not (c as Node3D).global_position.is_finite():
			bad += " car %s (process %s)" % [c.name, (c as Node).can_process()]
	if bad != "" and not has_meta(&"first"):
		var extra := ""
		var main: Node = get_meta(&"check").get(&"main")
		var cine: Node = main.get(&"cine") if main != null else null
		if cine != null:
			var cc: Variant = cine.get(&"car")
			extra = " | cine mode %s current %s, car %s" % [cine.get(&"mode"), (cine as Camera3D).current,
					(cc as Node).name if cc != null and is_instance_valid(cc) else "none"]
			if cc != null and is_instance_valid(cc):
				extra += " origin finite %s, interpolated finite %s" % [(cc as Node3D).global_position.is_finite(),
						(cc as Node3D).get_global_transform_interpolated().origin.is_finite()]
		var chase: Node = main.get(&"chase") if main != null else null
		if chase != null:
			extra += " | chase current %s at %s" % [(chase as Camera3D).current, (chase as Node3D).global_position]
		set_meta(&"first", "frame %d state %s: %s%s" % [frames, (g.State as Dictionary).find_key(g.state), bad, extra])
		print("NAN first: ", get_meta(&"first"))
"""
static var _NAN_WATCH: GDScript = null
var _watch: Node


## The two exact-look levers (hidden-object culling, fast ink pass): what each saves on every
## preset, and a full-resolution pixel comparison against the frame without it (time frozen).
func _exact_lever_checks(perf: Node) -> void:
	_check(int(perf.occluder_tris) > 100000 and main.map.has_node(^"TerrainOccluder") and root.use_occlusion_culling,
			"terrain occluder loaded (%dk tris), occlusion culling on" % (int(perf.occluder_tris) / 1000))
	var a0: Image = await _grab()
	await _frames(2)
	var a1: Image = await _grab()
	var noise := _pixels(a0, a1)
	_log("PARITY frame noise with nothing changed: %.4f%% pixels differ, max %d/255" % [noise[0] * 100.0, noise[1]])
	for q: String in ["high", "medium", "low"]:
		game.set_setting("quality", q)
		await _frames(6)
		perf.occlusion_on = false
		perf._enforce()
		await _frames(12)
		var off: Dictionary = await _census(perf)
		var img_off: Image = await _grab()
		perf.occlusion_on = true
		perf._enforce()
		await _frames(12)
		var on: Dictionary = await _census(perf)
		var img_on: Image = await _grab()
		var px := _pixels(img_off, img_on)
		_log("CENSUS q=%-6s hidden-object culling: main %4d -> %4d draws, %5dk -> %5dk tris | shadows %4d -> %4d draws | PARITY %.4f%% pixels differ, max %d/255" % [
				q, off["draws"], on["draws"], roundi(off["tris"] / 1000.0), roundi(on["tris"] / 1000.0),
				off["shadow_draws"], on["shadow_draws"], px[0] * 100.0, px[1]])
		_check(px[0] <= noise[0] + 0.0005, "hidden-object culling keeps the %s picture (%.4f%% pixels differ)" % [q, px[0] * 100.0])
		if px[0] > noise[0] + 0.0005:
			img_off.save_jpg(opts["out"] + "/10_culling_off_%s.jpg" % q, 0.9)
			img_on.save_jpg(opts["out"] + "/10_culling_on_%s.jpg" % q, 0.9)
	game.set_setting("quality", "high")
	await _frames(6)
	var ink_mat: ShaderMaterial = main.post.ink_material
	perf.ink_fast = false
	perf._enforce()
	await _frames(4)
	var orig_shader := ink_mat.shader
	var img_a: Image = await _grab()
	perf.ink_fast = true
	perf._enforce()
	await _frames(4)
	var img_b: Image = await _grab()
	var ink_px := _pixels(img_a, img_b)
	_log("PARITY q=high fast ink pass vs original: %.4f%% pixels differ (by more than 2/255), max %d/255, mean %.3f/255" % [ink_px[0] * 100.0, ink_px[1], ink_px[2]])
	_check(ink_mat.shader == perf.INK_FAST and orig_shader != perf.INK_FAST, "lab swaps the ink shader (fast <-> original)")
	_check(ink_px[0] <= noise[0] + 0.0005 and int(ink_px[1]) <= 6, "fast ink pass keeps the picture (%.4f%% pixels, max %d/255)" % [ink_px[0] * 100.0, ink_px[1]])
	if ink_px[0] > noise[0] + 0.0005 or int(ink_px[1]) > 6:
		img_a.save_jpg(opts["out"] + "/10_ink_original.jpg", 0.9)
		img_b.save_jpg(opts["out"] + "/10_ink_fast.jpg", 0.9)


## [fraction of pixels whose largest channel difference is over 2/255, largest difference,
## mean difference] at full resolution.
func _pixels(a: Image, b: Image) -> Array:
	var x := a.duplicate() as Image
	var y := b.duplicate() as Image
	x.convert(Image.FORMAT_RGB8)
	y.convert(Image.FORMAT_RGB8)
	var da := x.get_data()
	var db := y.get_data()
	var n := mini(da.size(), db.size())
	var changed := 0
	var top := 0
	var total := 0
	for i in range(0, n - 2, 3):
		var dd := maxi(absi(da[i] - db[i]), maxi(absi(da[i + 1] - db[i + 1]), absi(da[i + 2] - db[i + 2])))
		total += dd
		if dd > top:
			top = dd
		if dd > 2:
			changed += 1
	var count := maxi(n / 3, 1)
	return [float(changed) / count, top, float(total) / count]


func _cars() -> Array:
	var out := []
	for n in root.find_children("*", "", true, false):
		if n is Car:
			out.append(n)
	return out


## Visible geometry grouped by kind: [kind, triangles, objects, nearest m, note], heaviest first.
## shadow = casters only (cast_shadow on or shadows-only); otherwise what the main pass draws.
func _inventory(cam: Camera3D, max_dist: float, shadow: bool) -> Array:
	var rows := {}
	var p := cam.global_position
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if not g.is_visible_in_tree():
			continue
		if shadow and g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			continue
		if not shadow and g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			continue
		var box: AABB = g.global_transform * g.get_aabb()
		var d := (p.clamp(box.position, box.end) - p).length()
		if d > max_dist or (not shadow and g.visibility_range_end > 0.0 and d > g.visibility_range_end + g.visibility_range_end_margin):
			continue
		var info := _tris(g)
		var key := _kind(g)
		if not rows.has(key):
			rows[key] = [key, 0, 0, 1e9, ""]
		var r: Array = rows[key]
		r[1] += info[0]
		r[2] += 1
		r[3] = minf(r[3], d)
		if info[1] != "":
			r[4] = info[1]
	var out := rows.values()
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	return out


func _mesh_tris(m: Mesh) -> int:
	if m == null:
		return 0
	var t := 0
	if m is ArrayMesh:
		var am := m as ArrayMesh
		for s in am.get_surface_count():
			var ic := am.surface_get_array_index_len(s)
			t += (ic if ic > 0 else am.surface_get_array_len(s)) / 3
	else:
		t = m.get_faces().size() / 3
	return t


## [triangles, note]; inverted-hull outlines (next_pass) draw the mesh twice.
func _tris(g: GeometryInstance3D) -> Array:
	var note := ""
	var t := 0
	if g is MultiMeshInstance3D:
		var mm := (g as MultiMeshInstance3D).multimesh
		if mm != null:
			var count := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
			t = _mesh_tris(mm.mesh) * count
	elif g is MeshInstance3D:
		var mi := g as MeshInstance3D
		t = _mesh_tris(mi.mesh)
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(s)
				if mat != null and mat.next_pass != null:
					note = " (+outline pass)"
	else:
		note = " (%s)" % g.get_class()
	return [t, note]


func _kind(g: Node) -> String:
	var a := g.get_parent()
	while a != null and a != root:
		if a is Car:
			return "car %s" % a.name
		a = a.get_parent()
	var parent := String(g.get_parent().name)
	var nm := String(g.name)
	if parent == "Props":
		return "prop " + nm.rsplit("_", true, 2)[0]
	if parent == "Terrain":
		return "terrain " + ("far" if nm.ends_with("_far") else "near")
	var re := RegEx.create_from_string("[0-9_]+$")
	return "%s/%s" % [parent, re.sub(nm, "")]


func _census(perf: Node) -> Dictionary:
	var sum := {}
	var headless := DisplayServer.get_name() == "headless"
	for i in 3:
		# the headless dummy renderer never emits frame_post_draw
		if headless:
			await process_frame
		else:
			await RenderingServer.frame_post_draw
		var c: Dictionary = perf.census()
		for k: String in c:
			sum[k] = int(sum.get(k, 0)) + int(c[k])
	for k: String in sum:
		sum[k] = int(sum[k]) / 3
	return sum


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


## Mean absolute RGB difference (0..1) of two frames, on a 400-pixel-wide copy.
func _diff(a: Image, b: Image) -> float:
	var x := a.duplicate() as Image
	var y := b.duplicate() as Image
	var w := 400
	var h := maxi(roundi(400.0 * a.get_height() / maxf(a.get_width(), 1.0)), 1)
	x.resize(w, h, Image.INTERPOLATE_BILINEAR)
	y.resize(w, h, Image.INTERPOLATE_BILINEAR)
	var total := 0.0
	for j in h:
		for i in w:
			var p := x.get_pixel(i, j)
			var q := y.get_pixel(i, j)
			total += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
	return total / (w * h * 3.0)


func _left_menu() -> bool:
	var s := int(game.state)
	return s != int(game.State.MENU) and s != int(game.State.BOOT) and s != int(game.State.LOADING)


func _on_grid() -> bool:
	var s := int(game.state)
	return s == int(game.State.COUNTDOWN) or s == int(game.State.RACING)


func _finish() -> void:
	_log("SUMMARY: %d failures" % failures.size())
	for f in failures:
		_log("  FAIL %s" % f)
	game.request_quit(1 if failures.size() > 0 else 0)


# ---------------------------------------------------------------- touch helpers

## Canvas (viewport) coordinates → window coordinates, the space OS touch events arrive in.
func _to_window(p: Vector2) -> Vector2:
	var vis := root.get_visible_rect().size
	return p * (Vector2(root.size) / vis)


func _touch(index: int, id: String, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = _to_window(controls.button_center(id))
	Input.parse_input_event(ev)


## A finger tap on a Control (press, two frames, release) through the OS touch path. Godot turns
## it into the emulated mouse click that Buttons react to, exactly as on Android.
func _tap_control(c: Control) -> void:
	if c == null:
		_check(false, "tap target exists")
		return
	var p := _to_window(c.get_global_rect().get_center())
	_log("TAP %s at %s" % [c.name, p])
	var ev := InputEventScreenTouch.new()
	ev.index = 9
	ev.pressed = true
	ev.position = p
	Input.parse_input_event(ev)
	await _frames(3)
	var up := InputEventScreenTouch.new()
	up.index = 9
	up.pressed = false
	up.position = p
	Input.parse_input_event(up)
	await _frames(2)


func _drag(index: int, id: String) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = _to_window(controls.button_center(id))
	Input.parse_input_event(ev)


# ---------------------------------------------------------------- utils

func _check(ok: bool, what: String) -> void:
	_log("CHECK %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _log(s: String) -> void:
	print("[%6.1fs] %s" % [(Time.get_ticks_msec() - t0) / 1000.0, s])


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _until(cond: Callable, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout:
			_log("TIMEOUT (state=%s)" % (game.State as Dictionary).find_key(game.state))
			return
		await process_frame


func shot(name_: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [opts["out"], name_]
	root.get_texture().get_image().save_png(path)
	_log("SHOT %s" % path)
