extends CanvasLayer
## Sakura Rally: on-screen touch controls (Game-development-3rd-party, MIT).
##
## Layout (landscape):
##   left thumb   : steering zone (◀ ▶). Slide between the two halves without lifting.
##   right thumb  : GAS (big), BRAKE / reverse, HANDBRAKE above them. All three are slidable.
##   manual gears : ▲ / ▼ beside the pedals, only when Settings → Transmission is Manual.
##   right edge   : pause, camera and reset car (R).
## Held controls press the InputMap actions (throttle, brake, steer_left/right, handbrake), so
## CarInput reads them exactly like keys: its keyboard steering ramp applies. One-shot buttons
## send InputEventAction press/release pairs (pause is read from input events).
## Every touch is tracked by index, so several fingers work at once.

const UITheme := preload("res://scripts/ui/ui_theme.gd")

const HELD := [&"steer_left", &"steer_right", &"throttle", &"brake", &"handbrake"]

## Set by the Mobile autoload every frame: visible and accepting input only while driving.
var active := false:
	set(v):
		if v == active:
			return
		active = v
		if not v:
			release_all()
		_pad.visible = v

var _pad := Control.new()
var _buttons: Array[Dictionary] = []
var _steer_zone := Rect2()
var _steer_split := 0.0
## touch index -> button id
var _touches: Dictionary = {}
## action -> number of touches holding it
var _held: Dictionary = {}
var _vp_size := Vector2.ZERO


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_pad.name = "Pad"
	_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pad.draw.connect(_draw_pad)
	_pad.visible = false
	add_child(_pad)


func _process(_delta: float) -> void:
	var size := _pad.get_viewport_rect().size
	if size != _vp_size:
		_vp_size = size
		_layout(size)
	if _pad.visible:
		_pad.queue_redraw()


func _manual() -> bool:
	var game := get_node_or_null(^"/root/Game")
	return game != null and str(game.get_setting("transmission")) == "manual"


# ---------------------------------------------------------------- layout

func _layout(vp: Vector2) -> void:
	var W := vp.x
	var H := vp.y
	_buttons = [
		{"id": "left", "action": &"steer_left", "c": Vector2(185, H - 200), "r": 125.0, "icon": "left"},
		{"id": "right", "action": &"steer_right", "c": Vector2(470, H - 200), "r": 125.0, "icon": "right"},
		{"id": "throttle", "action": &"throttle", "c": Vector2(W - 195, H - 215), "r": 140.0, "label": "GAS",
				"tint": Color("3fae6a")},
		{"id": "brake", "action": &"brake", "c": Vector2(W - 475, H - 150), "r": 105.0, "label": "BRAKE",
				"tint": Color("d9534f")},
		{"id": "handbrake", "action": &"handbrake", "c": Vector2(W - 330, H - 470), "r": 92.0,
				"label": "HAND\nBRAKE", "tint": UITheme.SAKURA, "small_text": true},
		{"id": "shift_up", "tap": &"shift_up", "c": Vector2(W - 640, H - 345), "r": 64.0, "icon": "up",
				"manual": true},
		{"id": "shift_down", "tap": &"shift_down", "c": Vector2(W - 680, H - 160), "r": 64.0, "icon": "down",
				"manual": true},
		{"id": "pause", "tap": &"pause", "c": Vector2(W - 92, 300), "r": 56.0, "icon": "pause"},
		{"id": "camera", "tap": &"camera_next", "c": Vector2(W - 92, 430), "r": 56.0, "icon": "camera"},
		{"id": "reset", "tap": &"reset_car", "c": Vector2(W - 92, 560), "r": 56.0, "label": "R"},
	]
	# The steering zone covers the whole lower-left corner around both arrows.
	_steer_zone = Rect2(0, H * 0.45, 470 + 125 + 110, H * 0.55)
	_steer_split = (185.0 + 470.0) * 0.5


func _visible_buttons() -> Array[Dictionary]:
	var manual := _manual()
	var out: Array[Dictionary] = []
	for b in _buttons:
		if bool(b.get("manual", false)) and not manual:
			continue
		out.append(b)
	return out


func _hit(pos: Vector2) -> String:
	if _steer_zone.has_point(pos):
		return "left" if pos.x < _steer_split else "right"
	var best := ""
	var best_d := INF
	for b in _visible_buttons():
		var d: float = pos.distance_to(b["c"])
		if d <= float(b["r"]) * 1.18 and d < best_d:
			best = b["id"]
			best_d = d
	return best


func _button(id: String) -> Dictionary:
	for b in _buttons:
		if b["id"] == id:
			return b
	return {}


# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	if not active:
		return
	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			var id := _hit(touch.position)
			if id != "":
				_touch_down(touch.index, id)
				get_viewport().set_input_as_handled()
		elif _touches.has(touch.index):
			_set_touch(touch.index, "")
			get_viewport().set_input_as_handled()
		return
	var drag := event as InputEventScreenDrag
	if drag != null and _touches.has(drag.index):
		var cur: String = _touches[drag.index]
		var b := _button(cur)
		# Only held controls follow the finger (steer ↔ steer, pedal ↔ pedal); one-shot buttons
		# stay put until the finger lifts.
		if b.has("action"):
			var id := _hit(drag.position)
			var nb := _button(id)
			if id != cur and (id == "" or nb.has("action")):
				_set_touch(drag.index, id)
		get_viewport().set_input_as_handled()


func _touch_down(index: int, id: String) -> void:
	var b := _button(id)
	if b.has("tap"):
		_touches[index] = id
		_send(b["tap"], true)
		_buzz(18)
		return
	_set_touch(index, id)
	_buzz(12)


func _set_touch(index: int, id: String) -> void:
	var prev: String = _touches.get(index, "")
	if prev == id:
		return
	var pb := _button(prev)
	if pb.has("action"):
		_release(pb["action"])
	elif pb.has("tap"):
		_send(pb["tap"], false)
	if id == "":
		_touches.erase(index)
		return
	_touches[index] = id
	var b := _button(id)
	if b.has("action"):
		_press(b["action"])


func _press(action: StringName) -> void:
	var n: int = _held.get(action, 0)
	_held[action] = n + 1
	if n == 0:
		Input.action_press(action)


func _release(action: StringName) -> void:
	var n: int = _held.get(action, 0)
	if n <= 1:
		_held.erase(action)
		Input.action_release(action)
	else:
		_held[action] = n - 1


## One-shot buttons behave like a key: pressed while the finger is down, released when it lifts.
## Real InputEventActions, so both _unhandled_input readers (pause) and pollers (camera) see them.
func _send(action: StringName, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func release_all() -> void:
	for id in _touches.values():
		var b := _button(id)
		if b.has("tap"):
			_send(b["tap"], false)
	for a in HELD:
		Input.action_release(a)
	_held.clear()
	_touches.clear()


func is_held(id: String) -> bool:
	return _touches.values().has(id)


func _buzz(ms: int) -> void:
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(ms, 0.4)


## For CI: the button centres in viewport coordinates.
func button_center(id: String) -> Vector2:
	var b := _button(id)
	return b.get("c", Vector2(-1, -1))


# ---------------------------------------------------------------- drawing

func _draw_pad() -> void:
	var pressed := {}
	for id in _touches.values():
		pressed[id] = true
	for b in _visible_buttons():
		_draw_button(b, pressed.has(b["id"]))


func _draw_button(b: Dictionary, down: bool) -> void:
	var c: Vector2 = b["c"]
	var r: float = b["r"]
	var tint: Color = b.get("tint", UITheme.INK)
	var fill := Color(tint, 0.78 if down else 0.42)
	if not b.has("tint"):
		fill = Color(UITheme.INK, 0.62 if down else 0.36)
	var rr := r * (0.94 if down else 1.0)
	_pad.draw_circle(c + Vector2(0, 5), rr, Color(0, 0, 0, 0.16))
	_pad.draw_circle(c, rr, fill)
	_pad.draw_arc(c, rr - 2.5, 0.0, TAU, 64, Color(UITheme.PAPER, 0.92 if down else 0.7), 5.0, true)
	var ink := Color(UITheme.PAPER, 1.0 if down else 0.92)
	if b.has("icon"):
		_draw_icon(str(b["icon"]), c, r, ink)
	elif b.has("label"):
		var text: String = b["label"]
		var fs := int(r * (0.30 if bool(b.get("small_text", false)) else 0.36))
		var font: Font = UITheme.FONT_TITLE
		var lines := text.split("\n")
		var lh := font.get_height(fs)
		var y0 := c.y - lh * lines.size() * 0.5 + font.get_ascent(fs)
		for i in lines.size():
			var w := font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_pad.draw_string_outline(font, Vector2(c.x - w * 0.5, y0 + lh * i), lines[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color(UITheme.INK, 0.35))
			_pad.draw_string(font, Vector2(c.x - w * 0.5, y0 + lh * i), lines[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


func _draw_icon(icon: String, c: Vector2, r: float, ink: Color) -> void:
	var s := r * 0.36
	match icon:
		"left":
			_pad.draw_colored_polygon(PackedVector2Array([c + Vector2(-s, 0), c + Vector2(s * 0.7, -s),
					c + Vector2(s * 0.7, s)]), ink)
		"right":
			_pad.draw_colored_polygon(PackedVector2Array([c + Vector2(s, 0), c + Vector2(-s * 0.7, -s),
					c + Vector2(-s * 0.7, s)]), ink)
		"up":
			_pad.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -s), c + Vector2(s, s * 0.7),
					c + Vector2(-s, s * 0.7)]), ink)
		"down":
			_pad.draw_colored_polygon(PackedVector2Array([c + Vector2(0, s), c + Vector2(s, -s * 0.7),
					c + Vector2(-s, -s * 0.7)]), ink)
		"pause":
			var w := s * 0.55
			var h := s * 1.7
			_pad.draw_rect(Rect2(c + Vector2(-w * 1.6, -h * 0.5), Vector2(w, h)), ink)
			_pad.draw_rect(Rect2(c + Vector2(w * 0.6, -h * 0.5), Vector2(w, h)), ink)
		"camera":
			var body := Rect2(c + Vector2(-s * 1.15, -s * 0.6), Vector2(s * 2.3, s * 1.45))
			_pad.draw_rect(body, ink)
			_pad.draw_rect(Rect2(c + Vector2(-s * 0.45, -s * 0.9), Vector2(s * 0.9, s * 0.4)), ink)
			_pad.draw_circle(c + Vector2(0, s * 0.12), s * 0.5, Color(UITheme.INK, 0.85))
			_pad.draw_circle(c + Vector2(0, s * 0.12), s * 0.3, ink)
