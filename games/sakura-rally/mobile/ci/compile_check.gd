extends SceneTree
## CI: compiles every script of the mobile layer (res://mobile/**.gd) with the game's autoloads
## up, as the game itself does (godot --check-only compiles before the autoloads exist, so it
## rejects every script that names Game). Prints COMPILE ok / FAIL per script and exits 1 on any
## failure:
##
##   godot --headless --path . -s res://mobile/ci/compile_check.gd


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var files := PackedStringArray()
	_collect("res://mobile", files)
	files.sort()
	var bad := 0
	for f in files:
		print("COMPILE ...  %s" % f)
		var s := ResourceLoader.load(f, "Script", ResourceLoader.CACHE_MODE_IGNORE) as Script
		var ok := s != null and s.can_instantiate()
		bad += int(not ok)
		print("COMPILE %s %s" % ["ok  " if ok else "FAIL", f])
	print("SUMMARY compile_check: %d scripts, %d failed" % [files.size(), bad])
	quit(1 if bad > 0 else 0)


func _collect(dir: String, out: PackedStringArray) -> void:
	for d in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(d), out)
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
