extends Node
## Sakura Rally: Android / touch layer (Game-development-3rd-party, MIT).
##
## Registered as the `Mobile` autoload after `Game`. It does nothing on desktop unless the game
## is started with `-- --touch`, which CI uses for previews and tests. On phones it:
##   * picks phone-friendly defaults on first launch: Low quality, fullscreen (immersive);
##   * shows the touch controls (touch_controls.gd) only while the player is driving;
##   * hides the keyboard hint strip (shown again once a gamepad is used);
##   * moves the tachometer from the bottom-right corner (the pedal thumb) to the bottom centre
##     and enlarges the pause menu to finger size;
##   * maps the Android Back button onto the game's own flow: pause while driving, back out
##     of menus, resume from pause, and quit from the title hub;
##   * pauses a drive and releases every held control when the app goes to the background;
##   * runs the phone optimisations in perf_lab.gd (its fps meter and lab exist only in CI);
##   * on every platform, adds the race director (race/race_director.gd) to each race.
## Upstream scripts are not modified. Everything here goes through the public Game API, the
## InputMap actions and ui_cancel, the same paths the keyboard and gamepad already use.

const TouchControls := preload("res://mobile/touch_controls.gd")
const PerfLab := preload("res://mobile/perf_lab.gd")
const KeyHints := preload("res://scripts/ui/widgets/key_hints.gd")
const RaceDirector := preload("res://mobile/race/race_director.gd")

## Tachometer scale on touch screens (the desktop gauge is 400 px).
const TACH_SCALE := 0.62
## Pause menu scale on touch screens: its 58 px buttons become finger-sized (~5-6 mm on a phone).
const PAUSE_SCALE := 1.45

var touch_enabled := false
var controls: TouchControls
## Phone optimisations (perf_lab.gd); its fps meter and lab exist only in CI / `--perf` runs.
var perf: PerfLab

var _hud_done := false
## Keyboard hint strips ([W][A][S][D] Drive…): hidden on touch screens until a gamepad is used.
var _hints: Array[Control] = []
var _gamepad_seen := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	touch_enabled = OS.has_feature("mobile") or args.has("--touch")
	if OS.has_feature("mobile"):
		get_tree().quit_on_go_back = false
		_first_run_defaults()
	# Race mode on every platform of this build: the director (race_director.gd) joins each race.
	get_tree().node_added.connect(_on_race_node)
	if not touch_enabled:
		return
	controls = TouchControls.new()
	controls.name = "TouchControls"
	add_child(controls)
	perf = PerfLab.new()
	perf.name = "PerfLab"
	# The fps meter and lab are for testing only: off in the released game (phones), on in CI.
	var with_meter := args.has("--perf") or not OS.has_feature("mobile")
	perf.setup(self, args.has("--perf"), with_meter)
	add_child(perf)
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node.get_script() == KeyHints:
		var c := node as Control
		_hints.append(c)
		c.self_modulate.a = 1.0 if _gamepad_seen else 0.0


func _on_race_node(node: Node) -> void:
	if node is RaceField and not node.has_node(^"RaceDirector"):
		var director := RaceDirector.new()
		director.name = "RaceDirector"
		node.add_child.call_deferred(director)


func _input(event: InputEvent) -> void:
	if _gamepad_seen or not touch_enabled:
		return
	if event is InputEventJoypadButton:
		_gamepad_seen = true
		for c in _hints:
			if is_instance_valid(c):
				c.self_modulate.a = 1.0


## For CI: true when every keyboard hint strip on screen is hidden.
func hints_hidden() -> bool:
	var n := 0
	for c in _hints:
		if is_instance_valid(c) and c.is_inside_tree():
			n += 1
			if c.self_modulate.a > 0.01:
				return false
	return n > 0


func _first_run_defaults() -> void:
	var game := _game()
	if game == null or not bool(game.persistent):
		return
	if FileAccess.file_exists(str(game.SAVE_PATH)):
		return
	game.set_setting("quality", "low")
	game.set_setting("fullscreen", true)


func _process(_delta: float) -> void:
	if not touch_enabled:
		return
	if not _hud_done:
		_hud_done = _adapt_hud()
	controls.active = is_driving()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			handle_back()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			if controls != null:
				controls.release_all()
			var game := _game()
			if game != null and is_driving():
				game.set_paused(true)


# ---------------------------------------------------------------- state helpers

func _game() -> Node:
	return get_node_or_null(^"/root/Game")


func _main() -> Node:
	return get_tree().root.get_node_or_null(^"Main")


func _ui() -> Node:
	var main := _main()
	return main.get("ui") if main != null else null


## True while the player is in control of the car: countdown, timed stage, free roam or liaison,
## not paused, with no cover over the screen.
func is_driving() -> bool:
	var game := _game()
	if game == null or bool(game.paused):
		return false
	var s := int(game.state)
	var st: Dictionary = game.State
	if not (s == st.COUNTDOWN or s == st.RACING or s == st.FREE_ROAM or s == st.LIAISON):
		return false
	var ui := _ui()
	if ui != null and ui.has_method("is_screen_covered") and ui.is_screen_covered():
		return false
	return true


# ---------------------------------------------------------------- Back button

## Returns what it did: "resume", "pause", "quit" or "cancel". It is public so CI can drive it.
func handle_back() -> String:
	var game := _game()
	if game == null:
		return "none"
	if controls != null:
		controls.release_all()
	if bool(game.paused):
		# The pause menu (or its settings sheet) handles ui_cancel: close the sheet or resume.
		_inject(&"ui_cancel")
		return "resume"
	if is_driving():
		game.set_paused(true)
		return "pause"
	if int(game.state) == int(game.State.MENU) and _on_title_hub():
		game.request_quit()
		return "quit"
	_inject(&"ui_cancel")
	return "cancel"


func _on_title_hub() -> bool:
	var ui := _ui()
	if ui == null:
		return false
	var settings: Node = ui.get("settings")
	if settings != null and bool(settings.get("is_open")):
		return false
	var title: Node = ui.get("title")
	if title == null or str(title.get("view")) != "title":
		return false
	var confirm: Node = title.get("_confirm")
	if confirm != null and bool(confirm.get("is_open")):
		return false
	return true


func _inject(action: StringName) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	Input.parse_input_event(down)
	# Release a moment later, like a real key, so the press is never folded into the same frame.
	get_tree().create_timer(0.1, true, false, true).timeout.connect(func() -> void:
		var up := InputEventAction.new()
		up.action = action
		up.pressed = false
		Input.parse_input_event(up))


# ---------------------------------------------------------------- HUD layout

## Moves both HUDs' tachometers (race and liaison) to the bottom centre at TACH_SCALE, and
## scales the pause menu by PAUSE_SCALE.
## hud.gd docks the 400 px gauge at x = -446 inside a zero-size holder anchored bottom-right;
## re-anchoring the holder at the bottom centre with this offset centres it. The holder is moved
## and scaled, never the inner node, because the HUD's enter/exit tweens animate the inner node.
func _adapt_hud() -> bool:
	var ui := _ui()
	if ui == null:
		return false
	var done := 0
	for key: String in ["hud", "liaison_hud"]:
		var h: Node = ui.get(key)
		if h == null or not h.is_node_ready():
			continue
		var br: Control = h.get("_br")
		if br == null:
			continue
		br.anchor_left = 0.5
		br.anchor_right = 0.5
		br.anchor_top = 1.0
		br.anchor_bottom = 1.0
		var x := 246.0 * TACH_SCALE
		br.offset_left = x
		br.offset_right = x
		br.offset_top = 0.0
		br.offset_bottom = 0.0
		br.scale = Vector2(TACH_SCALE, TACH_SCALE)
		done += 1
	# Pause menu: its zero-size centre holder is anchored at the screen centre; the cascade tweens
	# animate the children, never the holder, so scaling the holder grows the menu about the centre.
	var pm: Node = ui.get("pause_menu")
	if pm != null and pm.is_node_ready():
		var center: Control = pm.get("_center")
		if center != null:
			center.scale = Vector2(PAUSE_SCALE, PAUSE_SCALE)
			done += 1
	return done == 3
