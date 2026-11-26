extends Node
## Terrain shadows cast from smaller pieces of the same triangles.
##
## The terrain is built as ~215 m chunks of 5000 triangles. Godot culls shadow casters per
## object, so every shadow cascade, even the first one that covers ~20 m around the car,
## re-draws every whole chunk it touches. In the CI census the terrain was 60% of all
## shadow-pass triangles on High.
##
## For the chunks within shadow reach of the camera, this hands the chunk's shadow casting to
## GRID x GRID shadow-only pieces cut from the very same triangles with the same material.
## The shadow map receives exactly the same depth, so the picture is identical; each cascade
## only draws the pieces it overlaps. The visible terrain is untouched. Pieces are cut on a
## worker thread from the map's raw data (no GPU read-back) and kept for the session.

const GRID := 4
const REACH := 180.0 ## metres beyond the sun's shadow distance (a chunk's half diagonal + margin)
const CHECK_INTERVAL := 0.25

var enabled := false:
	set(v):
		enabled = v
		_t = CHECK_INTERVAL
var stats := {"chunks": 0, "built": 0, "pieces": 0, "active": 0}

var _map: Node3D
var _terrain: Node3D
var _root: Node3D
var _chunks: Array[Dictionary] = [] ## {orig, center, d, pieces: Array, task: int, result}
var _t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 999999


func _process(delta: float) -> void:
	var map := _current_map()
	if map != _map:
		_reset(map)
	if _map == null:
		return
	if _chunks.is_empty() and _root == null:
		if not enabled:
			return
		_collect()
	_finish_tasks()
	_t += delta
	if _t < CHECK_INTERVAL:
		return
	_t = 0.0
	update_now()


## Re-evaluates which chunks cast through their pieces (tests call it to apply a change at once).
func update_now() -> void:
	if _root == null:
		return
	var cam := get_viewport().get_camera_3d()
	var reach := _shadow_distance() + REACH
	var active := 0
	for e in _chunks:
		var o: MeshInstance3D = e["orig"]
		if not is_instance_valid(o):
			continue
		var want := enabled and cam != null and _flat_distance(cam.global_position, e["center"]) < reach
		if want and (e["pieces"] as Array).is_empty() and int(e["task"]) < 0 and e["result"] == null:
			_start_task(e)
		var on := want and not (e["pieces"] as Array).is_empty()
		for p: MeshInstance3D in e["pieces"]:
			p.visible = on
		var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if o.cast_shadow != cast:
			o.cast_shadow = cast
		if on:
			active += 1
	stats["active"] = active


## Waits for every chunk in reach to have its pieces (tests).
func build_all_now() -> void:
	update_now()
	for e in _chunks:
		if int(e["task"]) >= 0:
			WorkerThreadPool.wait_for_task_completion(e["task"])
	_finish_tasks()
	update_now()


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _shadow_distance() -> float:
	var atmo: Variant = _map.get("atmosphere")
	var sun: Variant = (atmo as Node).get("sun") if atmo != null else null
	if sun is DirectionalLight3D:
		return (sun as DirectionalLight3D).directional_shadow_max_distance
	return 320.0


func _current_map() -> Node3D:
	var main := get_tree().root.get_node_or_null(^"Main")
	if main == null:
		return null
	var map: Variant = main.get("map")
	if map == null or not is_instance_valid(map) or not bool((map as Node).get("is_built")):
		return null
	return map


func _reset(map: Node3D) -> void:
	for e in _chunks:
		if int(e["task"]) >= 0:
			WorkerThreadPool.wait_for_task_completion(e["task"])
		var o: Variant = e["orig"]
		if is_instance_valid(o):
			(o as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_chunks.clear()
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_terrain = null
	_map = map
	stats = {"chunks": 0, "built": 0, "pieces": 0, "active": 0}


func _collect() -> void:
	_terrain = _map.get_node_or_null(^"Terrain")
	var info: Variant = _map.get("info")
	if _terrain == null or not (info is Dictionary) or not (info as Dictionary).has("meshes"):
		return
	var by_name := {}
	for d: Dictionary in (info as Dictionary)["meshes"]:
		if d.get("material", "") == "terrain" and not d.get("local", false):
			by_name[d["name"]] = d
	_root = Node3D.new()
	_root.name = "ShadowPieces"
	_terrain.add_child(_root)
	for node in _terrain.get_children():
		var o := node as MeshInstance3D
		if o == null or o.mesh == null or not by_name.has(String(o.name)):
			continue
		if o.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON or o.visibility_range_begin > 0.0:
			continue # far-only chunks never reach the shadow cascades
		var d: Dictionary = by_name[String(o.name)]
		if not "idx" in (d["attrs"] as Array):
			continue
		var center := o.global_transform * o.get_aabb().get_center()
		_chunks.append({"orig": o, "center": center, "d": d, "pieces": [], "task": -1, "result": null})
	stats["chunks"] = _chunks.size()


func _start_task(e: Dictionary) -> void:
	var bin: PackedByteArray = _map.get("bin")
	var d: Dictionary = e["d"]
	var holder := [null] # the worker writes only here; read after the task completes
	e["result"] = holder
	e["task"] = WorkerThreadPool.add_task(func() -> void: holder[0] = cut(bin, d, GRID), false, "shadow pieces")


func _finish_tasks() -> void:
	for e in _chunks:
		var id: int = e["task"]
		if id < 0 or not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		e["task"] = -1
		var holder: Array = e["result"]
		var parts: Variant = holder[0]
		e["result"] = null
		var o: MeshInstance3D = e["orig"]
		if not is_instance_valid(o) or not (parts is Array):
			continue
		var mat: Material = o.get_active_material(0)
		var list: Array = []
		for arr: Array in parts:
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			mesh.surface_set_material(0, mat)
			var p := MeshInstance3D.new()
			p.name = "%s_s%d" % [o.name, list.size()]
			p.mesh = mesh
			p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			p.layers = o.layers
			p.visible = false
			_root.add_child(p)
			p.transform = o.transform
			p.reset_physics_interpolation()
			list.append(p)
		e["pieces"] = list
		stats["built"] += 1
		stats["pieces"] += list.size()


## The chunk's triangles grouped by their centre into grid x grid pieces (positions, normals and
## indices; the terrain shader's vertex stage only reads the position). Pure data: runs on a
## worker thread.
static func cut(bin: PackedByteArray, d: Dictionary, grid: int) -> Array:
	var off: int = d["offset"]
	var vc: int = d["vcount"]
	var ic: int = d["icount"]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	for a: String in d["attrs"]:
		match a:
			"pos":
				verts = bin.slice(off, off + vc * 12).to_vector3_array()
				off += vc * 12
			"nrm":
				normals = bin.slice(off, off + vc * 12).to_vector3_array()
				off += vc * 12
			"col":
				off += vc * 16
			"uv":
				off += vc * 8
			"idx":
				idx = bin.slice(off, off + ic * 4).to_int32_array()
				off += ic * 4
	if verts.is_empty() or idx.size() < 3:
		return []
	var lo := verts[0]
	var hi := verts[0]
	for v in verts:
		lo = lo.min(v)
		hi = hi.max(v)
	var size := Vector2(maxf(hi.x - lo.x, 0.001), maxf(hi.z - lo.z, 0.001))
	var lists: Array = [] # plain Arrays: packed arrays would be copied on every append
	lists.resize(grid * grid)
	for i in lists.size():
		lists[i] = []
	for t in range(0, idx.size() - 2, 3):
		var a := verts[idx[t]]
		var b := verts[idx[t + 1]]
		var c := verts[idx[t + 2]]
		var cx := (a.x + b.x + c.x) / 3.0
		var cz := (a.z + b.z + c.z) / 3.0
		var gx := clampi(int((cx - lo.x) / size.x * grid), 0, grid - 1)
		var gz := clampi(int((cz - lo.z) / size.y * grid), 0, grid - 1)
		var l: Array = lists[gx + gz * grid]
		l.append(idx[t])
		l.append(idx[t + 1])
		l.append(idx[t + 2])
	var out := []
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	for l: Array in lists:
		if l.is_empty():
			continue
		remap.fill(-1)
		var pv := PackedVector3Array()
		var pn := PackedVector3Array()
		var pi := PackedInt32Array()
		pi.resize(l.size())
		for k in l.size():
			var src: int = l[k]
			var dst := remap[src]
			if dst < 0:
				dst = pv.size()
				remap[src] = dst
				pv.append(verts[src])
				if not normals.is_empty():
					pn.append(normals[src])
			pi[k] = dst
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pv
		if not pn.is_empty():
			arr[Mesh.ARRAY_NORMAL] = pn
		arr[Mesh.ARRAY_INDEX] = pi
		out.append(arr)
	return out
