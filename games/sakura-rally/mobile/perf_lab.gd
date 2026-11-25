extends CanvasLayer
## Sakura Rally: performance meter and lab (Game-development-3rd-party, MIT).
##
## Added by mobile.gd on phones (and in CI). Two parts:
##   * the meter: one tap-able strip in the top-right corner with fps, frame time, CPU time
##     (game logic, physics, render submission), GPU time, the limiting side, draw calls,
##     triangles, the 3D resolution, the screen refresh rate and the quality preset;
##   * the lab: tapping the meter pauses the drive and opens switches that change one cost at a
##     time, live: frame-rate cap, 3D resolution, sun shadows, ink lines and colour grade.
##     Comparing the meter before/after each switch shows what limits the frame rate on a given
##     device. "Copy report" puts the numbers on the clipboard.
## Only the meter setting and the frame-rate cap are saved (user://mobile_perf.cfg); the test
## switches reset on every launch, so the game always starts with its normal look.
## Upstream scripts are not modified: the lab only sets public engine properties and re-asserts
## its overrides each frame after the game's own Quality.apply().

const CFG_PATH := "user://mobile_perf.cfg"
## Frame-rate caps (0 = up to the screen's refresh). 72 and 48 divide 144 Hz evenly.
const CAPS := [0, 120, 90, 72, 60, 48, 30]
## 3D render scales (0 = whatever the game's quality preset chose).
const SCALES := [0.0, 1.0, 0.85, 0.7, 0.5]
## Physics catch-up limit on phones (upstream: 12). The tick stays 120 Hz, so the handling is
## unchanged; it only stops one slow frame from making the next one slower.
const MAX_PHYSICS_STEPS := 4
const SAMPLE_SECONDS := 0.5
## GPU profile: each step switches one part of the frame off (or sets one 3D resolution) for
## PROFILE_SETTLE + PROFILE_MEASURE seconds while the car is held still, and records the GPU time.
const PROFILE_STEPS := [
	["base", "As you play"],
	["res100", "3D 100%"],
	["res50", "3D 50%"],
	["res25", "3D 25%"],
	["ink", "Ink lines off"],
	["grade", "Colour grade off"],
	["shadows", "Sun shadows off"],
	["outlines", "Outline pass off"],
	["props", "Trees/rocks/buildings off"],
	["ground", "Terrain/road/water off"],
	["skyfx", "Clouds/petals off"],
	["ui", "HUD + touch buttons off"],
	["world", "Whole 3D world off"],
]
const PROFILE_SETTLE := 0.8
const PROFILE_MEASURE := 1.7
## Process order: the stamp runs before every other node's _process, the lab after all of them,
## so the time between the two is the game's own script work for the frame (Godot's
## TIME_PROCESS monitor also includes drawing and waiting for the GPU, so it can't tell them apart).
const FIRST := -1000000
const LAST := 1000000


class Stamp extends Node:
	var usec := 0

	func _process(_delta: float) -> void:
		usec = Time.get_ticks_usec()
const FONT_SIZE := 21

var meter_on := true
var cap_i := 0
var scale_i := 0
var shadows_on := true
var ink_on := true
var grade_on := true
var lab_open := false

## Latest computed numbers (also read by CI and the report).
var stats := {}

var _mobile: Node
var _meter: Button
var _panel: PanelContainer
var _rows := {} ## key -> Button
var _report_btn: Button
var _vp_rid: RID
var _acc := {"t": 0.0, "n": 0, "worst": 0.0, "rcpu": 0.0, "gpu": 0.0, "logic": 0.0}
var _stamp: Stamp
var profiling := false
## Results of the last GPU profile: [{key, label, fps, gpu, cpu, draws}].
var profile_rows: Array[Dictionary] = []
var _profile_scale := 0.0
## CI shortens the profile (software rendering is very slow); 1.0 on devices.
var profile_time_scale := 1.0
var _profile_btn: Button
var _results: Label
var _outline_cache := {} ## Material -> its outline next_pass, while the outline step runs


func setup(mobile: Node, meter_default: bool) -> void:
	_mobile = mobile
	meter_on = meter_default
	_load()


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = LAST
	_stamp = Stamp.new()
	_stamp.name = "PerfStamp"
	_stamp.process_mode = Node.PROCESS_MODE_ALWAYS
	_stamp.process_priority = FIRST
	add_child(_stamp)
	if OS.has_feature("mobile"):
		Engine.max_physics_steps_per_frame = MAX_PHYSICS_STEPS
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_build_meter()
	_build_panel()
	_apply_cap()
	_refresh_rows()


# ---------------------------------------------------------------- UI

func _style(bg: Color, radius: int = 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _button(text: String, size_px: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", size_px)
	b.add_theme_color_override("font_color", Color(0.98, 0.96, 0.92))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 0.85, 0.9))
	b.add_theme_stylebox_override("normal", _style(Color(0.1, 0.09, 0.14, 0.72)))
	b.add_theme_stylebox_override("hover", _style(Color(0.16, 0.14, 0.22, 0.82)))
	b.add_theme_stylebox_override("pressed", _style(Color(0.55, 0.2, 0.35, 0.9)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _build_meter() -> void:
	_meter = _button("…", FONT_SIZE)
	_meter.name = "PerfMeter"
	_meter.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_meter.anchor_left = 1.0
	_meter.anchor_right = 1.0
	_meter.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_meter.offset_right = -16.0
	_meter.offset_top = 14.0
	_meter.pressed.connect(_on_meter_pressed)
	add_child(_meter)


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "PerfLab"
	_panel.add_theme_stylebox_override("panel", _style(Color(0.08, 0.07, 0.11, 0.86), 18))
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.offset_right = -24.0
	_panel.custom_minimum_size = Vector2(500, 0)
	_panel.visible = false
	add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_panel.add_child(col)
	var head := Label.new()
	head.text = "Performance lab"
	head.add_theme_font_size_override("font_size", 28)
	head.add_theme_color_override("font_color", Color(1, 0.8, 0.88))
	col.add_child(head)
	var note := Label.new()
	note.text = "Change one switch, resume, drive, read the meter.\nTest switches reset on restart."
	note.add_theme_font_size_override("font_size", 18)
	note.add_theme_color_override("font_color", Color(0.85, 0.83, 0.8))
	col.add_child(note)
	for key: String in ["cap", "scale", "shadows", "ink", "grade", "meter"]:
		var b := _button("", 24)
		b.name = "Lab_" + key
		b.custom_minimum_size = Vector2(0, 64)
		b.pressed.connect(_on_row.bind(key))
		col.add_child(b)
		_rows[key] = b
	_profile_btn = _button("Profile GPU (30 s, car still)", 24)
	_profile_btn.name = "Lab_profile"
	_profile_btn.custom_minimum_size = Vector2(0, 64)
	_profile_btn.pressed.connect(run_profile)
	col.add_child(_profile_btn)
	_results = Label.new()
	_results.name = "ProfileResults"
	_results.add_theme_font_size_override("font_size", 17)
	_results.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	_results.visible = false
	col.add_child(_results)
	_report_btn = _button("Copy report", 24)
	_report_btn.custom_minimum_size = Vector2(0, 64)
	_report_btn.pressed.connect(copy_report)
	col.add_child(_report_btn)
	var close := _button("Close lab", 24)
	close.custom_minimum_size = Vector2(0, 64)
	close.pressed.connect(func() -> void:
		lab_open = false
		_update_visibility())
	col.add_child(close)


func _refresh_rows() -> void:
	var cap: int = CAPS[cap_i]
	_rows["cap"].text = "Frame-rate cap:  %s" % ("Screen max" if cap == 0 else "%d fps" % cap)
	var s: float = SCALES[scale_i]
	_rows["scale"].text = "3D resolution:  %s" % ("Game setting" if s == 0.0 else "%d%%" % roundi(s * 100.0))
	_rows["shadows"].text = "Sun shadows:  %s" % ("On" if shadows_on else "OFF (test)")
	_rows["ink"].text = "Ink lines:  %s" % ("On" if ink_on else "OFF (test)")
	_rows["grade"].text = "Colour grade:  %s" % ("On" if grade_on else "OFF (test)")
	_rows["meter"].text = "Meter:  %s" % ("Shown" if meter_on else "Hidden")


func _on_row(key: String) -> void:
	match key:
		"cap":
			cap_i = (cap_i + 1) % CAPS.size()
			_apply_cap()
		"scale":
			scale_i = (scale_i + 1) % SCALES.size()
			if SCALES[scale_i] == 0.0:
				_restore_game_scale()
		"shadows":
			shadows_on = not shadows_on
		"ink":
			ink_on = not ink_on
		"grade":
			grade_on = not grade_on
		"meter":
			meter_on = not meter_on
	_refresh_rows()
	_save()
	_enforce()


func _on_meter_pressed() -> void:
	lab_open = true
	if _mobile != null and _mobile.is_driving():
		var game := _game()
		if game != null:
			game.set_paused(true)
	_update_visibility()


func _update_visibility() -> void:
	var driving: bool = _mobile != null and _mobile.is_driving()
	_panel.visible = lab_open and not driving
	# While the lab is open the meter stays visible even if hidden, so the numbers can be read.
	_meter.visible = meter_on or _panel.visible


# ---------------------------------------------------------------- overrides

func _game() -> Node:
	return get_node_or_null(^"/root/Game")


func _main() -> Node:
	return get_tree().root.get_node_or_null(^"Main")


func _apply_cap() -> void:
	Engine.max_fps = CAPS[cap_i]


func _restore_game_scale() -> void:
	var game := _game()
	var q := str(game.get_setting("quality")) if game != null else "high"
	Quality.apply_render_scale(q, get_window())


## Re-asserts the lab overrides. The game re-applies its quality preset on map loads and
## setting changes, so this runs every frame but only writes what differs.
func _enforce() -> void:
	var win := get_window()
	var s: float = _profile_scale if _profile_scale > 0.0 else SCALES[scale_i]
	if s > 0.0 and not is_equal_approx(win.scaling_3d_scale, s):
		win.scaling_3d_scale = s
		win.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if s < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
	var main := _main()
	if main == null:
		return
	var map: Node = main.get("map")
	if map != null and bool(map.get("is_built")):
		var atmo: Node = map.get("atmosphere")
		var sun: DirectionalLight3D = atmo.get("sun") if atmo != null else null
		if sun != null and sun.shadow_enabled != shadows_on:
			sun.shadow_enabled = shadows_on
	var post: Node = main.get("post")
	if post != null:
		var quad: Node3D = post.get("ink_quad")
		# The game hides the ink itself in some views (PostFX.set_enabled); only force it off.
		if quad != null and not ink_on and quad.visible:
			quad.visible = false
		elif quad != null and ink_on and bool(quad.get_meta(&"lab_hidden", false)):
			quad.visible = true
		if quad != null:
			quad.set_meta(&"lab_hidden", not ink_on)
		var grade: CanvasItem = post.get("grade_rect")
		if grade != null and grade.visible != grade_on:
			grade.visible = grade_on


# ---------------------------------------------------------------- measuring

func _process(delta: float) -> void:
	var logic_ms := 0.0 if _stamp.usec == 0 else maxf(Time.get_ticks_usec() - _stamp.usec, 0) / 1000.0
	_enforce()
	_update_visibility()
	var ms := delta * 1000.0
	_acc["t"] += delta
	_acc["n"] += 1
	_acc["worst"] = maxf(_acc["worst"], ms)
	_acc["rcpu"] += RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid) \
			+ RenderingServer.get_frame_setup_time_cpu()
	_acc["gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	_acc["logic"] += logic_ms
	if _acc["t"] < SAMPLE_SECONDS:
		return
	var n := float(_acc["n"])
	var frame_ms: float = _acc["t"] * 1000.0 / n
	var fps := 1000.0 / maxf(frame_ms, 0.001)
	var ticks := float(Engine.physics_ticks_per_second)
	var steps := clampf(ticks / maxf(fps, 1.0), 1.0, float(Engine.max_physics_steps_per_frame))
	var scripts: float = _acc["logic"] / n
	var physics := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var render_cpu: float = _acc["rcpu"] / n
	var gpu: float = _acc["gpu"] / n
	var cpu := scripts + physics * steps + render_cpu
	var cap: int = CAPS[cap_i]
	var refresh := DisplayServer.screen_get_refresh_rate()
	if refresh <= 1.0 or refresh > 1000.0:
		refresh = 0.0
	# The GPU is the limit when it is busy for most of the frame; otherwise the frame waits on the
	# CPU side (scripts, physics, draw submission) or on a cap / the screen.
	var limit := "CPU"
	if cap > 0 and fps >= cap * 0.95:
		limit = "cap"
	elif refresh > 0.0 and fps >= refresh * 0.95:
		limit = "screen"
	elif gpu <= 0.01:
		limit = "CPU? (no GPU timer)"
	elif gpu >= frame_ms * 0.85:
		limit = "GPU"
	var win := get_window()
	var game := _game()
	stats = {
		"fps": fps, "frame_ms": frame_ms, "worst_ms": float(_acc["worst"]),
		"cpu_ms": cpu, "scripts_ms": scripts, "physics_ms": physics, "physics_steps": steps,
		"render_cpu_ms": render_cpu, "gpu_ms": gpu, "limit": limit,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"triangles": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"window": win.size, "scale_3d": win.scaling_3d_scale, "msaa": win.msaa_3d,
		"refresh_hz": refresh,
		"quality": str(game.get_setting("quality")) if game != null else "?",
	}
	_acc = {"t": 0.0, "n": 0, "worst": 0.0, "rcpu": 0.0, "gpu": 0.0, "logic": 0.0}
	if not profiling:
		_meter.text = _meter_text()


func _meter_text() -> String:
	var s := stats
	var w: Vector2i = s["window"]
	var sc: float = s["scale_3d"]
	var hz: float = s["refresh_hz"]
	return "%d fps  %.1f ms (worst %.0f)  ·  limit: %s\nCPU %.1f ms  [game logic %.1f · physics %.1f×%.0f · render %.1f]   GPU %.1f ms\n3D %d×%d (%d%%) · %s Hz · %d draws · %dk tris · %s" % [
		roundi(s["fps"]), s["frame_ms"], s["worst_ms"], s["limit"],
		s["cpu_ms"], s["scripts_ms"], s["physics_ms"], s["physics_steps"], s["render_cpu_ms"], s["gpu_ms"],
		roundi(w.x * sc), roundi(w.y * sc), roundi(sc * 100.0), ("%d" % roundi(hz)) if hz > 0.0 else "?",
		s["draw_calls"], roundi(s["triangles"] / 1000.0), str(s["quality"]).capitalize()]


## Puts a plain-text report on the clipboard (and in user://perf_report.txt).
func copy_report() -> String:
	var lines := PackedStringArray()
	lines.append("Sakura Rally perf report")
	lines.append("device: %s | %s | %d cores" % [OS.get_model_name(), OS.get_processor_name(), OS.get_processor_count()])
	lines.append("gpu: %s | %s | %s" % [RenderingServer.get_video_adapter_name(),
			RenderingServer.get_video_adapter_api_version(), RenderingServer.get_current_rendering_method()])
	lines.append("switches: cap=%s scale=%s shadows=%s ink=%s grade=%s" % [
			CAPS[cap_i], SCALES[scale_i], shadows_on, ink_on, grade_on])
	lines.append(_meter_text() if not stats.is_empty() else "(no sample yet)")
	var text := "\n".join(lines)
	DisplayServer.clipboard_set(text)
	var f := FileAccess.open("user://perf_report.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
	if _report_btn != null:
		_report_btn.text = "Copied ✓"
		get_tree().create_timer(1.5, true, false, true).timeout.connect(func() -> void:
			_report_btn.text = "Copy report")
	return text


# ---------------------------------------------------------------- GPU profile

## Holds the car still and measures the GPU time of the frame with each part switched off in
## turn (PROFILE_STEPS). Shows the table in the lab and puts it on the clipboard.
func run_profile() -> void:
	if profiling:
		return
	profiling = true
	profile_rows.clear()
	lab_open = false
	var game := _game()
	if game != null and bool(game.paused):
		game.set_paused(false)
	var saved_cap := cap_i
	cap_i = 0
	_apply_cap()
	Input.action_press(&"handbrake")
	await _wait(1.5 * profile_time_scale)
	var i := 0
	for step: Array in PROFILE_STEPS:
		i += 1
		_meter.text = "Profiling %d/%d: %s …\nKeep the car still, don't touch the screen." % [i, PROFILE_STEPS.size(), step[1]]
		_profile_step(step[0], true)
		await _wait(PROFILE_SETTLE * profile_time_scale)
		var r := await _measure(PROFILE_MEASURE * profile_time_scale)
		_profile_step(step[0], false)
		r["key"] = step[0]
		r["label"] = step[1]
		profile_rows.append(r)
	Input.action_release(&"handbrake")
	cap_i = saved_cap
	_apply_cap()
	profiling = false
	var text := profile_text()
	DisplayServer.clipboard_set(text)
	var f := FileAccess.open("user://perf_profile.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
	_results.text = _profile_table() + "\n(copied to the clipboard)"
	_results.visible = true
	lab_open = true
	if game != null and _mobile != null and _mobile.is_driving():
		game.set_paused(true)
	_update_visibility()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _measure(seconds: float) -> Dictionary:
	var t := 0.0
	var n := 0
	var gpu := 0.0
	var rcpu := 0.0
	var draws := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		n += 1
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
		rcpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid) + RenderingServer.get_frame_setup_time_cpu()
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	n = maxi(n, 1)
	return {"fps": n / maxf(t, 0.001), "gpu": gpu / n, "cpu": rcpu / n, "draws": roundi(draws / n)}


var _saved := {}


func _profile_step(key: String, on: bool) -> void:
	var main := _main()
	var map: Node = main.get("map") if main != null else null
	match key:
		"res100", "res50", "res25":
			_profile_scale = ({"res100": 1.0, "res50": 0.5, "res25": 0.25}[key] as float) if on else 0.0
			if not on and SCALES[scale_i] == 0.0:
				_restore_game_scale()
		"ink":
			if on:
				_saved["ink"] = ink_on
			ink_on = false if on else bool(_saved.get("ink", true))
		"grade":
			if on:
				_saved["grade"] = grade_on
			grade_on = false if on else bool(_saved.get("grade", true))
		"shadows":
			if on:
				_saved["shadows"] = shadows_on
			shadows_on = false if on else bool(_saved.get("shadows", true))
		"outlines":
			_set_outlines(not on)
		"props":
			_set_visible(map, ["Props"], not on)
		"ground":
			_set_visible(map, ["Terrain", "Road", "Water"], not on)
		"skyfx":
			_set_visible(map, ["SkyRig"], not on)
		"ui":
			var ui: Node = main.get("ui") if main != null else null
			if ui is CanvasLayer:
				(ui as CanvasLayer).visible = not on
			if _mobile != null and _mobile.get("controls") is CanvasLayer:
				(_mobile.get("controls") as CanvasLayer).visible = not on
		"world":
			var cam := get_viewport().get_camera_3d()
			if cam != null:
				if on:
					_saved["cull"] = cam.cull_mask
					cam.cull_mask = 0
				else:
					cam.cull_mask = int(_saved.get("cull", 0xFFFFF))
	_enforce()


func _set_visible(map: Node, names: Array, on: bool) -> void:
	if map == null:
		return
	for nm: String in names:
		var n := map.get_node_or_null(NodePath(nm)) as Node3D
		if n != null:
			n.visible = on


## Removes (on = false) or restores the outline hull passes of every material in the scene.
func _set_outlines(on: bool) -> void:
	if on:
		for m: Material in _outline_cache:
			m.next_pass = _outline_cache[m]
		_outline_cache.clear()
		return
	var main := _main()
	if main == null:
		return
	for node in main.find_children("*", "GeometryInstance3D", true, false):
		var gi := node as GeometryInstance3D
		var mats: Array = [gi.material_override]
		var mesh: Mesh = null
		if gi is MeshInstance3D:
			var mi := gi as MeshInstance3D
			mesh = mi.mesh
			for k in mi.get_surface_override_material_count():
				mats.append(mi.get_surface_override_material(k))
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			mesh = (gi as MultiMeshInstance3D).multimesh.mesh
		if mesh != null:
			for k in mesh.get_surface_count():
				mats.append(mesh.surface_get_material(k))
		for m in mats:
			var mat := m as Material
			if mat != null and mat.next_pass != null and not _outline_cache.has(mat):
				_outline_cache[mat] = mat.next_pass
				mat.next_pass = null


func _profile_table() -> String:
	if profile_rows.is_empty():
		return ""
	var base: float = profile_rows[0]["gpu"]
	var lines := PackedStringArray()
	for r: Dictionary in profile_rows:
		var d: float = float(r["gpu"]) - base
		lines.append("%s: %d fps · GPU %.1f ms%s" % [r["label"], roundi(r["fps"]), r["gpu"],
				"" if r["key"] == "base" else " (%+.1f)" % d])
	return "\n".join(lines)


## The full profile as plain text (device line, settings, one line per step).
func profile_text() -> String:
	var win := get_window()
	var game := _game()
	var head := "Sakura Rally GPU profile\ndevice: %s | %s | %s %s\nscreen: %dx%d @ %s Hz | quality %s | 3D scale %.2f\n" % [
			OS.get_model_name(), RenderingServer.get_video_adapter_name(),
			RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_api_version(),
			win.size.x, win.size.y, str(roundi(DisplayServer.screen_get_refresh_rate())),
			str(game.get_setting("quality")) if game != null else "?", win.scaling_3d_scale]
	var lines := PackedStringArray()
	for r: Dictionary in profile_rows:
		lines.append("%-26s %5.1f fps  GPU %6.2f ms  render-CPU %5.2f ms  %4d draws" % [
				r["label"], r["fps"], r["gpu"], r["cpu"], r["draws"]])
	return head + "\n".join(lines)


# ---------------------------------------------------------------- persistence

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	meter_on = bool(cfg.get_value("perf", "meter", meter_on))
	cap_i = clampi(CAPS.find(int(cfg.get_value("perf", "cap", 0))), 0, CAPS.size() - 1)


func _save() -> void:
	var game := _game()
	if game != null and not bool(game.get("persistent")):
		return
	var cfg := ConfigFile.new()
	cfg.set_value("perf", "meter", meter_on)
	cfg.set_value("perf", "cap", CAPS[cap_i])
	cfg.save(CFG_PATH)
