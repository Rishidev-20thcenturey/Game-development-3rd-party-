extends Node
## Finer prop cells around the camera: the same trees, drawn with the detail they need.
##
## MapWorld groups every prop into 160 m MultiMesh chunks. Godot picks a mesh LOD per
## MultiMesh, from the distance along the view direction to the chunk's box, and uses 0 (full
## detail) whenever the box crosses the camera plane. So the camera's chunk, its neighbours and
## a whole row of chunks beside the car draw every tree at full detail, in the main pass and in
## every shadow cascade, even trees 150 m away.
##
## For the chunks around the camera this swaps each tree or bush chunk for CELL-sized cells.
## Each cell is a MultiMesh with the same mesh, materials, transforms, shadow casting and layers,
## so every tree is still drawn and lit the same way. Only the LOD each one gets is the same as
## a lone tree at that distance. A chunk is only swapped while its own visibility range shows it
## fully (not fading), so nothing appears or disappears that the chunk would not show.
## Smashable, crowd and soft-upright props are left alone (SoftCourse and Crowd edit their
## MultiMeshes).

const CHUNK := 160.0 ## MapWorld.CHUNK
const CELL := 80.0
const CATEGORIES := ["tree", "vegetation"]
const NEAR := 1 ## chunks around the camera's chunk that may be swapped (3 x 3)
const CHECK_INTERVAL := 0.1

var enabled := false:
	set(v):
		enabled = v
		_t = CHECK_INTERVAL
var stats := {"chunks": 0, "cells": 0, "instances": 0, "active": 0}

var _map: Node3D
var _props: Node3D
var _root: Node3D
var _by_chunk := {} ## Vector2i -> Array[Dictionary] {orig, cells, center}
var _active := {} ## orig instance id -> entry
var _t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 999999 # after the camera has moved this frame


func _process(delta: float) -> void:
	var map := _current_map()
	if map != _map:
		_reset(map)
	if _root == null:
		if enabled and _map != null:
			_build()
		return
	if not is_instance_valid(_props):
		return
	_root.visible = _props.visible
	_t += delta
	if _t < CHECK_INTERVAL:
		return
	_t = 0.0
	update_now()


## Re-evaluates which chunks are swapped (also called by tests to apply a change at once).
func update_now() -> void:
	if _root == null:
		return
	var cam := get_viewport().get_camera_3d()
	var want := {}
	if enabled and cam != null:
		var p := cam.global_position
		var ck := Vector2i(floori(p.x / CHUNK), floori(p.z / CHUNK))
		for dx in range(-NEAR, NEAR + 1):
			for dz in range(-NEAR, NEAR + 1):
				for e: Dictionary in _by_chunk.get(ck + Vector2i(dx, dz), []):
					if _fully_shown(e, p):
						want[(e["orig"] as Object).get_instance_id()] = e
	for id: int in _active.keys():
		if not want.has(id):
			_swap(_active[id], false)
			_active.erase(id)
	for id: int in want:
		var e: Dictionary = want[id]
		if not _active.has(id):
			_swap(e, true)
			_active[id] = e
		else:
			_sync(e)
	stats["active"] = _active.size()


## The chunk's own visibility range shows it without fading (MapWorld fades over the margin;
## Godot measures from the camera to the box centre).
func _fully_shown(e: Dictionary, cam_pos: Vector3) -> bool:
	var o: MultiMeshInstance3D = e["orig"]
	if not is_instance_valid(o):
		return false
	var end := o.visibility_range_end
	if end <= 0.0:
		return true
	return cam_pos.distance_to(e["center"]) < end - 2.0 * o.visibility_range_end_margin - 10.0


func _swap(e: Dictionary, fine: bool) -> void:
	var o: MultiMeshInstance3D = e["orig"]
	if not is_instance_valid(o):
		return
	if fine:
		_sync(e)
	for c: MultiMeshInstance3D in e["cells"]:
		c.visible = fine
	o.visible = not fine


func _sync(e: Dictionary) -> void:
	var o: MultiMeshInstance3D = e["orig"]
	for c: MultiMeshInstance3D in e["cells"]:
		if c.cast_shadow != o.cast_shadow:
			c.cast_shadow = o.cast_shadow


func _current_map() -> Node3D:
	var main := get_tree().root.get_node_or_null(^"Main")
	if main == null:
		return null
	var map: Variant = main.get("map")
	if map == null or not is_instance_valid(map) or not bool((map as Node).get("is_built")):
		return null
	return map


func _reset(map: Node3D) -> void:
	for e: Dictionary in _active.values():
		_swap(e, false)
	_active.clear()
	_by_chunk.clear()
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_props = null
	_map = map
	stats = {"chunks": 0, "cells": 0, "instances": 0, "active": 0}


func _build() -> void:
	_props = _map.get_node_or_null(^"Props")
	if _props == null:
		return
	var manifest: Dictionary = _map.get("manifest")
	_root = Node3D.new()
	_root.name = "PropsFine"
	_map.add_child(_root)
	for node in _props.get_children():
		var o := node as MultiMeshInstance3D
		if o == null or o.multimesh == null:
			continue
		var parts := String(o.name).rsplit("_", true, 2)
		if parts.size() != 3 or not parts[1].is_valid_int() or not parts[2].is_valid_int():
			continue
		var prop := parts[0]
		var cat: String = (manifest.get(prop, {}) as Dictionary).get("category", "")
		if not cat in CATEGORIES or SoftCourse.is_smashable(prop) or Crowd.is_person(prop) \
				or prop in SoftCourse.SOFT_UPRIGHT_PROPS:
			continue
		var mm := o.multimesh
		if mm.use_custom_data or mm.use_colors or mm.transform_format != MultiMesh.TRANSFORM_3D:
			continue
		var cells := _split(o, mm)
		if cells.is_empty():
			continue
		var key := Vector2i(int(parts[1]), int(parts[2]))
		if not _by_chunk.has(key):
			_by_chunk[key] = []
		var center := o.global_transform * mm.get_aabb().get_center()
		(_by_chunk[key] as Array).append({"orig": o, "cells": cells, "center": center})
		stats["chunks"] += 1
		stats["cells"] += cells.size()
		stats["instances"] += mm.instance_count
	_t = CHECK_INTERVAL


## The chunk's instances grouped by CELL; empty when they all fall in one cell anyway.
func _split(o: MultiMeshInstance3D, mm: MultiMesh) -> Array:
	var groups := {}
	var xf := o.global_transform
	for i in mm.instance_count:
		var t := mm.get_instance_transform(i)
		var w := xf * t.origin
		var k := Vector2i(floori(w.x / CELL), floori(w.z / CELL))
		if not groups.has(k):
			groups[k] = []
		(groups[k] as Array).append(t)
	if groups.size() < 2:
		return []
	var out := []
	for k: Vector2i in groups:
		var list: Array = groups[k]
		var cm := MultiMesh.new()
		cm.transform_format = MultiMesh.TRANSFORM_3D
		cm.mesh = mm.mesh
		cm.instance_count = list.size()
		for j in list.size():
			cm.set_instance_transform(j, list[j])
		var c := MultiMeshInstance3D.new()
		c.name = "%s_c%d_%d" % [o.name, k.x, k.y]
		c.multimesh = cm
		c.cast_shadow = o.cast_shadow
		c.layers = o.layers
		c.material_override = o.material_override
		c.lod_bias = o.lod_bias
		c.gi_mode = o.gi_mode
		c.visible = false
		_root.add_child(c)
		c.global_transform = xf
		c.reset_physics_interpolation()
		out.append(c)
	return out
