# SPDX-License-Identifier: 0BSD
extends Node3D
## Single-player presentation adapter. Timer work is independent of world size.
const Runtime = preload("res://addons/audio_runtime/audio_runtime.gd")
const Cadence = preload("res://addons/audio_runtime/footstep_cadence.gd")
const KainoMap = preload("res://addons/audio_runtime/kaino_audition_map.gd")
const HELD_TORCH_GAIN_DB := -6.0
const EVENT_LOG := "user://audio_events.log"
const LOG_LIMIT := 262144
const RELOAD_SECONDS := 1.0
var cadence := Cadence.new()
var game: Node
var audio: Node3D
var timer: Timer
var initialized := false
var epoch := -1
var last_position := Vector3.ZERO
var soundscape_seconds := 0.0
var bed := 0
var bed_gain := -60.0
var fire_handles: Dictionary = {}
var fire_collections: Array[Node3D] = []
var surfaces: Dictionary = {}
var settings := ConfigFile.new()
var persist_settings := false
var sample_token := 810000000
var pending: Dictionary = {}
var last_surface := ""
var surface_cache: Dictionary = {}
var suspended := false
var mapping_path := KainoMap.DEFAULT_SELECTION
var mapping_stamp := -1
var base_files: Dictionary = {}
var reload_seconds := 0.0
var material_tokens: Dictionary = {}
var material_token := 820000000
## Sampled ground material per 2 m cell, so digging keeps remembering what the
## ground is made of as the player moves along a slope.
var surface_samples: Dictionary = {}
## The generic event has no sound of its own: it stays silent until assigned,
## instead of borrowing a footstep from another material.
const REQUIRES_ASSIGNMENT := ["world.break.block"]
const REPEAT_MS := 90
var assigned: Dictionary = {}
var last_event_ms: Dictionary = {}

func attach(host: Node) -> void:
	game = host; name = "WorldAudio"
	timer = Timer.new(); timer.wait_time = 1.0 / 60.0; timer.process_callback = Timer.TIMER_PROCESS_PHYSICS
	timer.timeout.connect(tick); add_child(timer); timer.start()

func initialize() -> void:
	initialized = true
	audio = Runtime.new(); audio.name = "Playback"; add_child(audio)
	if not audio.prepare(Runtime.Catalog.enabled_paths()):
		# Reject the external set atomically, then retain the bundled default.
		push_warning("Audio packs rejected: " + str(audio.catalog.diagnostics))
		var builtin := "res://addons/audio_runtime/packs/nox/pack.audio.module.json"
		audio.prepare(PackedStringArray([builtin]) if FileAccess.file_exists(builtin) else PackedStringArray())
	for id: String in audio.catalog.sounds:
		base_files[id] = (audio.catalog.sounds[id] as Dictionary).get("files", []).duplicate()
	reload_mapping(true)
	persist_settings = not game.temporary_world and not ProjectSettings.get_setting("terraforest/offscreen_session", false)
	if persist_settings: settings.load("user://audio_preferences.cfg")
	audio.set_enabled(bool(settings.get_value("audio", "enabled", true)))
	for bus: String in Runtime.BUSES: audio.set_volume(bus, float(settings.get_value("audio", bus, .8)))
	for key: String in game.structures._models:
		var collection: Node3D = game.structures._models[key]
		var material: String = game.structures.object_definitions.get(key, {}).get("durability", {}).get("material", "")
		surfaces[collection.get_instance_id()] = "metal" if "metal" in key or "iron" in key else ("wood" if material == "wood" or "wood" in key or "floor" in key else "rock")
		if ("fireplace" in key or "standing_torch" in key or "campfire" in key) and fire_collections.size() < 8: fire_collections.append(collection)
	game.terrain.density_ray_received.connect(receive_surface)
	add_controls()
	reset_world()

func add_controls() -> void:
	var menu: CanvasLayer = game.session_menu
	if not menu.built: return
	menu.navigation["Audio"] = menu.button(menu.navigation["Graphics"].get_parent(), "Audio", menu.show_page.bind("Audio"))
	menu.navigation["Graphics"].get_parent().move_child(menu.navigation["Audio"], menu.navigation["Graphics"].get_index() + 1)
	var page: VBoxContainer = menu.page("Audio")
	menu.label(page, "Audio").add_theme_font_size_override("font_size", 22)
	var toggle := CheckButton.new(); toggle.text = "Environment and footsteps"; toggle.button_pressed = audio.enabled
	toggle.toggled.connect(func(value: bool): audio.set_enabled(value); preference("enabled", value)); page.add_child(toggle)
	for bus: String in Runtime.BUSES:
		menu.label(page, bus)
		var slider := HSlider.new(); slider.min_value = 0; slider.max_value = 1; slider.step = .01
		slider.value = clampf(float(settings.get_value("audio", bus, .8)), 0, 1); slider.custom_minimum_size.x = 320
		slider.value_changed.connect(func(value: float): audio.set_volume(bus, value); preference(bus, value)); page.add_child(slider)

func preference(key: String, value: Variant) -> void:
	settings.set_value("audio", key, value)
	if persist_settings: settings.save("user://audio_preferences.cfg")

func reset_world() -> void:
	audio.clear(); bed = 0; bed_gain = -60; fire_handles.clear(); pending.clear(); surface_cache.clear(); cadence.reset(); soundscape_seconds = 0
	epoch = game.terrain.epoch; last_position = game.player.global_position

func active() -> bool:
	return game.terrain.world_ready and not game.loading_active and not game.shutdown_requested and game.app_focused and not game.benchmark_enabled and not game.session_menu.pauses_world() and not game.player_view.entry.active and not game.player_life.dead

func tick() -> void:
	if not is_instance_valid(game): return
	if not initialized:
		if game.get("startup_complete") == true and game.session_menu.built: initialize()
		return
	if epoch != game.terrain.epoch: reset_world()
	audio.listener = game.camera.global_position
	reload_seconds += timer.wait_time
	if reload_seconds >= RELOAD_SECONDS:
		reload_seconds = 0.0
		reload_mapping()
	if not active() or not audio.enabled:
		if not suspended: reset_world()
		suspended = true; return
	if suspended: last_position = game.player.global_position; cadence.reset()
	suspended = false
	if not pending.is_empty() and Time.get_ticks_msec() - pending.started > 100: pending.clear()
	var position: Vector3 = game.player.global_position
	var travelled := Vector2(position.x - last_position.x, position.z - last_position.z).length()
	last_position = position
	var speed := Vector2(game.player.velocity.x, game.player.velocity.z).length()
	if cadence.advance(travelled, speed, not game.fly and not game.world_vehicle.driving and game.player.is_on_floor()):
		footstep(position, "run" if speed > 7 else "walk")
	soundscape_seconds += timer.wait_time
	if soundscape_seconds >= .25:
		soundscape_seconds = fmod(soundscape_seconds, .25); soundscape()

func footstep(position: Vector3, gait: String) -> void:
	var hit: Dictionary = game.structures.blocks.raycast_scene(position + Vector3.UP * .35, position - Vector3.UP * .65, 7, [game.player.get_rid()])
	if hit.is_empty(): return
	var surface := "grass" if hit.get("normal", Vector3.UP).y > .8 else "rock"
	var collider: Object = hit.get("collider")
	if collider != null and collider.has_meta("audio_surface"): surface = str(collider.get_meta("audio_surface"))
	elif collider == game.structures.blocks and hit.has("cell"):
		surface = ["rock", "wood", "rock", "metal"][clampi(int(game.structures.blocks.decode_block(game.structures.blocks.get_cell(hit.cell)).material), 0, 3)]
	elif collider != null and surfaces.has(collider.get_instance_id()): surface = surfaces[collider.get_instance_id()]
	var point: Vector3 = hit.position
	if game._player_water_depth() > .05: return
	if game.lakes.depth_at(point + Vector3.UP * .05) > .03: surface = "water"
	# Cached native material improves the next step; playback never waits for it.
	var natural: bool = surface in ["grass", "rock"] and (collider == null or not surfaces.has(collider.get_instance_id())) and collider != game.structures.blocks
	if natural:
		var fallback_surface := surface
		if not surface_cache.is_empty() and surface_cache.revision == game.terrain.native_revision and surface_cache.position.distance_squared_to(point) <= 9:
			surface = surface_cache.surface
		if pending.is_empty():
			sample_token += 1
			pending = {"position": point, "surface": fallback_surface, "started": Time.get_ticks_msec()}
			if not game.terrain.request_density_ray(point + Vector3.UP * .3, point - Vector3.UP * .5, sample_token, 32, true): pending.clear()
	last_surface = surface
	audio.emit_event("movement.footstep", {"position": point, "surface": surface, "gait": gait})

func receive_surface(reply: Dictionary) -> void:
	if material_tokens.has(reply.get("token", 0)):
		var asked: Vector3 = material_tokens[reply.get("token", 0)]
		material_tokens.erase(reply.get("token", 0))
		if reply.get("status", "") == "hit" and reply.has("surface_material"):
			var at: Vector3 = reply.get("position", asked)
			var sampled := surface_name(int(reply.surface_material), reply, "dirt")
			var revision := int(reply.get("revision", game.terrain.native_revision))
			surface_samples[sample_key(at)] = {"surface": sampled, "revision": revision}
			surface_cache = {"position": at, "surface": sampled, "revision": revision}
		return
	if pending.is_empty() or game.terrain.epoch != epoch or reply.get("token") != sample_token or reply.get("epoch") != epoch or reply.get("revision") != game.terrain.native_revision: return
	if reply.get("status") != "hit" or not reply.has("surface_material") or reply.position.distance_squared_to(pending.position) > .5: return
	var surface := surface_name(int(reply.surface_material), reply, pending.surface)
	surface_cache = {"position": reply.position, "surface": surface, "revision": reply.revision}
	pending.clear()

func surface_name(material: int, reply: Dictionary, fallback: String) -> String:
	var surface: String = {1: "rock", 2: "wood", 3: "metal", 4: "rock", 8: "metal", 9: "metal", 10: "dirt"}.get(material, fallback)
	if material == 0 and (reply.get("surface_depth", 0) > 1.5 or reply.get("normal", Vector3.UP).y < .65): surface = "rock"
	if material == 0 and float(reply.get("position", Vector3.ZERO).y) > 175 and reply.get("normal", Vector3.UP).y > .8: surface = "snow"
	return surface

## Ask the terrain what the ground is made of before it breaks; the answer lands
## a frame or two later and is reused by material_at().
func prime_material(point: Vector3) -> void:
	if audio == null or not point.is_finite(): return
	material_token += 1
	material_tokens[material_token] = point
	if not game.terrain.request_density_ray(point + Vector3.UP * .3, point - Vector3.UP * .5, material_token, 32, true):
		material_tokens.erase(material_token)

func sample_key(point: Vector3) -> Vector3i:
	return Vector3i((point / 2.0).floor())

## The sampled surface at (or near) a point, empty when nothing fresh is known.
func material_at(point: Vector3) -> String:
	if audio == null or not point.is_finite(): return ""
	var revision: int = game.terrain.native_revision
	var key := sample_key(point)
	for dx: int in [-1, 0, 1]:
		for dz: int in [-1, 0, 1]:
			for dy: int in [-1, 0, 1]:
				var sample: Dictionary = surface_samples.get(key + Vector3i(dx, dy, dz), {})
				if sample.is_empty() or int(sample.get("revision", -1)) != revision: continue
				return str(sample.get("surface", ""))
	if not surface_cache.is_empty() and int(surface_cache.get("revision", -1)) == revision:
		if (surface_cache.get("position", Vector3.ZERO) as Vector3).distance_squared_to(point) <= 9.0:
			return str(surface_cache.get("surface", ""))
	return ""

## One event at one position, played through the audition-mapped catalog. Every
## emit is logged with the file it resolved to, so a silent event is visible.
## local events belong to the player's own action: they play at the listener so
## the volume never depends on how far the hit was. Events caused elsewhere
## pass local = false and keep their world position for distance falloff.
func play_event(id: String, point: Vector3, local: bool = true) -> void:
	if audio == null or not point.is_finite(): return
	if id in REQUIRES_ASSIGNMENT and not assigned.has(id):
		note("event %s skipped: no assigned sound" % id)
		return
	var now := Time.get_ticks_msec()
	if now - int(last_event_ms.get(id, -1000000)) < REPEAT_MS: return
	last_event_ms[id] = now
	var row: Dictionary = audio.catalog.sounds.get(id, {})
	var files: Array = row.get("files", [])
	note("event %s -> %s%s%s" % [id, str(files[0]) if not files.is_empty() else "unresolved", "" if audio.enabled else " (audio disabled)", " (local)" if local else " (positional)"])
	if not audio.enabled: return
	audio.emit_event(id, {"position": audio.listener if local else point})

func note(text: String) -> void:
	var path := ProjectSettings.globalize_path(EVENT_LOG)
	if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path).length() > LOG_LIMIT:
		DirAccess.remove_absolute(path)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null: file = FileAccess.open(path, FileAccess.WRITE)
	if file == null: return
	file.seek_end()
	file.store_line("%s  %s" % [Time.get_time_string_from_system(), text])
	file.close()

## The audition selection is re-read while the world runs, so an assignment
## takes effect without restarting anything.
func reload_mapping(force: bool = false) -> int:
	if audio == null: return 0
	var stamp := FileAccess.get_modified_time(ProjectSettings.globalize_path(mapping_path))
	if not force and stamp == mapping_stamp: return 0
	mapping_stamp = stamp
	for id: String in base_files:
		var row: Dictionary = audio.catalog.sounds.get(id, {})
		if row.is_empty(): continue
		row["files"] = (base_files[id] as Array).duplicate()
		audio.catalog.sounds[id] = row
	var applied: int = KainoMap.apply(audio.catalog, mapping_path)
	assigned = {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ProjectSettings.globalize_path(mapping_path))) if FileAccess.file_exists(ProjectSettings.globalize_path(mapping_path)) else null
	if parsed is Dictionary and parsed.get("selection", {}) is Dictionary:
		for key: Variant in parsed["selection"]: assigned[str(key)] = true
	note("mapping %d entries from %s (stamp %d)" % [applied, mapping_path, stamp])
	return applied

func soundscape() -> void:
	var point: Vector3 = game.player.global_position
	# Reuse the existing forest cell index: one O(1) occupancy lookup, no tree scan.
	var renderer: Node3D = game.vegetation.renderer
	var cell := Vector2i(floori(point.x / renderer.CELL), floori(point.z / renderer.CELL))
	var occupied: bool = renderer.cells.has(cell) and not renderer.cells[cell].rows.is_empty()
	var roof: Dictionary = game.structures.blocks.raycast_scene(point + Vector3.UP * 1.8, point + Vector3.UP * 14, 7, [game.player.get_rid()])
	var target := 0.0 if occupied and roof.is_empty() else -60.0
	bed_gain = move_toward(bed_gain, target, 5.0)
	if bed == 0 and bed_gain > -60: bed = audio.start_loop("ambience.forest", {}, true)
	if bed > 0 and not audio.update_loop(bed, point, bed_gain): bed = 0
	if bed_gain <= -60 and bed > 0: audio.stop(bed); bed = 0
	var wanted := {}
	# Only collision-resident fires, already selected by native world streaming.
	# Fixed maxima: eight collections, 128 total candidates, eight audible fires.
	var visited := 0
	for collection in fire_collections:
		if visited >= 128: break
		if not is_instance_valid(collection): continue
		var ids: PackedInt64Array = collection.collision_identities()
		for i in mini(ids.size(), 128):
			if visited >= 128: break
			visited += 1
			var transform: PackedFloat32Array = collection.get_instance(ids[i])
			if transform.size() != 12: continue
			var source: Vector3 = collection.to_global(Vector3(transform[9], transform[10], transform[11]) + Vector3.UP * .6)
			if source.distance_squared_to(audio.listener) > 16 * 16 or wanted.size() >= 8: continue
			wanted[str(collection.get_instance_id()) + ":" + str(ids[i])] = source
	var torch: Node3D = game.tool_view.human.torch_effects
	if is_instance_valid(torch) and torch.burning and torch.is_visible_in_tree(): wanted["held-torch"] = torch.global_position
	for key: String in fire_handles.keys():
		if not wanted.has(key): audio.stop(fire_handles[key]); fire_handles.erase(key)
	for key: String in wanted:
		var gain_db := HELD_TORCH_GAIN_DB if key == "held-torch" else 0.0
		if fire_handles.has(key) and not audio.update_loop(fire_handles[key], wanted[key], gain_db): fire_handles.erase(key)
		if not fire_handles.has(key):
			var handle: int = audio.start_loop("fire.burn", {"position": wanted[key]})
			if handle > 0:
				fire_handles[key] = handle
				audio.update_loop(handle, wanted[key], gain_db)
