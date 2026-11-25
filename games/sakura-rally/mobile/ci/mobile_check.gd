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

	# ------------------------------------------------------------ back to the menu
	game.request_menu()
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 60.0)
	await _seconds(1.0)
	_check(not bool(controls.active), "controls hidden again on the menu")

	# ------------------------------------------------------------ campaign started by a tap
	await _until(func() -> bool: return not bool(main.ui.title._switching), 20.0)
	await _seconds(1.0)
	await _tap_control(main.ui.title._campaign_item)
	await _until(_left_menu, 90.0)
	_check(_left_menu(), "tapping New journey starts the campaign (state=%s)" % (game.State as Dictionary).find_key(game.state))
	await _seconds(3.0)
	await shot("07_campaign")
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
			and not Input.is_action_pressed(&"handbrake") and Engine.max_fps == 0,
			"GPU profile puts everything back (scale %.2f, mask %d)" % [win.scaling_3d_scale, root.get_camera_3d().cull_mask])
	_check(bool(perf._results.visible) and bool(perf._panel.visible), "GPU profile shows its table in the lab")
	await shot("09_profile")
	perf.lab_open = false
	perf.meter_on = false
	game.set_paused(false)
	await _seconds(0.4)
	_check(not bool(game.paused) and not bool(perf._panel.visible), "lab closed, drive resumed")


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
