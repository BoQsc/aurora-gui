# SPDX-License-Identifier: 0BSD
extends Node3D
const Barrel=preload("res://addons/player_runtime/combat_barrel.gd")
const Durability=preload("res://addons/player_runtime/durability_catalog.gd")
const RIFLE:=7
const AMMO:=221
const WEAPONS={7:{"title":"CARBINE","ammo":221,"interval":.4,"speed":180.0,"damage":35,"block_damage":18},8:{"title":"RANGER AR","ammo":223,"interval":.10,"speed":240.0,"damage":24,"block_damage":12}}
const PROJECTILE_LIMIT:=64
var game:Node
# Input ownership is supplied by the host, allowing non-mouse controllers and
# offscreen validation without changing the desktop pointer.
var action_input_owned:Callable
var state:RefCounted
var barrels:Node3D
var effects=preload("res://addons/player_runtime/destruction_effects.gd").new()
var integrity=preload("res://addons/player_runtime/structural_integrity.gd").new()
var projectiles:Array[Dictionary]=[]
var detonations:Array[int]=[]
var blast_jobs:Array[Dictionary]=[]
var reload_slot:=-1
var reload_epoch:=-1
var reload_weapon:=-1
var shot_random:=RandomNumberGenerator.new()
var epoch:=-1
var timer:=0.0
var next_shot:=0.0
var hits:=0
var shots:=0
var holes:Node3D
var explosions:=0
var destroyed_blocks:=0
var ammo_label:Label
var integrity_toggle:CheckButton
var audio_pool:Array[AudioStreamPlayer3D]=[]
var shot_audio:AudioStreamWAV
var blast_audio:AudioStreamWAV
var assault_audio:AudioStreamWAV
var restored_support_pending:=true
func prepare(host:Node)->bool:
	game=host;state=ClassDB.instantiate("NativeCombatState")
	action_input_owned=func()->bool:return Input.mouse_mode==Input.MOUSE_MODE_CAPTURED
	if state==null or barrels==null:return false
	add_child(effects);effects.blocks=game.structures.blocks;integrity.attach(game,self)
	holes=preload("res://addons/player_runtime/bullet_holes.gd").new();add_child(holes)
	holes.source=func()->int:return game.terrain.native_revision
	game.tool_view.human.rifle_reload_finished.connect(finish_reload)
	shot_audio=sound(.18,72);blast_audio=sound(.65,38);assault_audio=sound(.13,110);shot_random.randomize()
	return game.persistence.register_component("combat",capture,restore,state,state.capture_storage_snapshot())
func capture()->PackedByteArray:
	if not state.set_blast_jobs(blast_jobs):push_error("Combat destruction queue could not be captured");return PackedByteArray()
	_save_holes()
	return state.capture_storage_snapshot()
func restore(bytes:PackedByteArray)->bool:
	if not state.restore_storage_snapshot(bytes):return false
	cancel_reload();clear_transients();integrity.reset()
	_load_holes()
	blast_jobs.assign(state.get_blast_jobs());epoch=game.terrain.epoch;restored_support_pending=true
	if integrity_toggle!=null:integrity_toggle.set_pressed_no_signal(state.integrity_enabled())
	return true
func add_controls(menu:CanvasLayer,parent:Node)->void:
	integrity_toggle=CheckButton.new();integrity_toggle.text="Structural integrity and collapse (optional)"
	integrity_toggle.tooltip_text="Check nearby blocks after building, mining and explosions. Unsupported blocks fall. Off by default; saved with this world."
	integrity_toggle.button_pressed=state.integrity_enabled();integrity_toggle.toggled.connect(set_integrity);parent.add_child(integrity_toggle)
	menu.label(parent,"Firearms: hold left mouse to fire · right mouse aims · R reloads. Craft a Carbine or Ranger assault rifle and matching cartridges, or use Dev Bag. Equip a barrel and right-click loaded ground to place it.")
func set_integrity(enabled:bool)->void:
	state.set_integrity_enabled(enabled);integrity.reset();game.terrain.changed_since_save=true
	if enabled:integrity.changed(AABB(game.player.global_position-Vector3.ONE,Vector3.ONE*2))
func active()->bool:
	return game!=null and game.terrain.world_ready and not game.loading_active and not game.shutdown_requested and game.app_focused and not game.session_menu.visible_ui() and not game.player_hud.inventory_open and not game.storage.opened and not game.benchmark_enabled
func can_use()->bool:
	# Development mode is a testing mode: a weapon handed out there must fire.
	return active() and not game.world_vehicle.driving and not game.player_view.entry.blocks_actions() and action_input_owned.is_valid() and action_input_owned.call() and game._model_edit_available()
func handle_input(event:InputEvent)->bool:
	if game.equipped_tool in WEAPONS:
		if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_R:reload();return true
		if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]:
			if event.button_index==MOUSE_BUTTON_LEFT and event.pressed:fire()
			return true
	if game.equipped_tool==Barrel.ITEM and event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_RIGHT:
		if event.pressed:place_barrel()
		return true
	return false
func rounds_in_bag(weapon:int=0)->int:
	if weapon==0:weapon=game.equipped_tool if game.equipped_tool in WEAPONS else RIFLE
	var ammunition:int=WEAPONS.get(weapon,WEAPONS[RIFLE]).ammo
	var total:=0
	for slot:Dictionary in game.player_hud.inventory.snapshot().slots:
		if slot.item==ammunition:total+=int(slot.count)
	return total
func fire()->bool:
	var weapon:int=game.equipped_tool
	if not can_use() or weapon not in WEAPONS or reload_slot>=0 or timer+.000001<next_shot or projectiles.size()>=PROJECTILE_LIMIT:return false
	var human:Node=game.tool_view.human
	if human.current!=weapon or human.action_remaining>0:return false
	if state.get_rounds(weapon)<=0:
		next_shot=timer+.4;reload();return false
	var origin:Vector3=game.camera.global_position
	var direction:Vector3=-game.camera.global_basis.z
	if weapon==8:
		var spread:=tan(deg_to_rad(.25 if human.rifle_aiming else 1.15))
		var radius:=sqrt(shot_random.randf())*spread;var angle:=shot_random.randf()*TAU
		direction=(direction+game.camera.global_basis.x*cos(angle)*radius+game.camera.global_basis.y*sin(angle)*radius).normalized()
	if not launch(origin,direction,weapon):return false
	# Development testing fires without consuming rounds, so a gun handed out in
	# the developer bag can be tried without a supply chain.
	if not game.session_menu.developer and not state.take_round(weapon):return false
	human.rifle_action("Fire" if human.rifle_aiming else "HipFire")
	shots+=1;next_shot=timer+float(WEAPONS[weapon].interval);game.terrain.changed_since_save=true
	game.zombies.hear_noise(origin,64);play_sound(origin,assault_audio if weapon==8 else shot_audio)
	return true
func reload()->bool:
	var weapon:int=game.equipped_tool
	if not can_use() or weapon not in WEAPONS or reload_slot>=0 or state.get_rounds(weapon)>=30:return false
	if rounds_in_bag(weapon)<=0:game._show_lake_notice("No matching cartridges · craft or find ammunition");return false
	if not game.tool_view.human.rifle_action("Reload"):return false
	reload_slot=game.player_hud.active_slot;reload_epoch=game.terrain.epoch;reload_weapon=weapon;return true
func finish_reload()->void:
	if reload_slot<0:return
	if not can_use() or game.equipped_tool!=reload_weapon or game.player_hud.active_slot!=reload_slot or game.terrain.epoch!=reload_epoch:cancel_reload();return
	var count:=mini(30-state.get_rounds(reload_weapon),rounds_in_bag(reload_weapon))
	var inventory:RefCounted=game.player_hud.inventory
	if count>0 and inventory.consume_items(PackedInt64Array([WEAPONS[reload_weapon].ammo,count]),inventory.snapshot().revision).ok:
		state.load_rounds(count,reload_weapon);game.terrain.changed_since_save=true;game.player_hud.refresh()
	reload_slot=-1;reload_weapon=-1
func cancel_reload()->void:
	reload_slot=-1;reload_weapon=-1
	if game!=null:game.tool_view.human.cancel_rifle_reload()
func launch(origin:Vector3,direction:Vector3,weapon:int=RIFLE)->bool:
	if weapon not in WEAPONS or not origin.is_finite() or not direction.is_finite() or direction.length_squared()<.9 or projectiles.size()>=PROJECTILE_LIMIT:return false
	var tracer:=MeshInstance3D.new();var mesh:=BoxMesh.new();mesh.size=Vector3(.018,.018,.6);tracer.mesh=mesh
	var material:=StandardMaterial3D.new();material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;material.albedo_color=Color(1,.83,.3);tracer.material_override=material;tracer.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tracer);tracer.global_position=origin
	# Capture the shot's payload: equipping another weapon cannot change a bullet in flight.
	projectiles.append({"position":origin,"velocity":direction.normalized()*float(WEAPONS[weapon].speed),"damage":int(WEAPONS[weapon].damage),"block_damage":int(WEAPONS[weapon].block_damage),"age":0.0,"view":tracer,"epoch":game.terrain.epoch})
	return true
func step_projectiles(delta:float)->void:
	for index in range(projectiles.size()-1,-1,-1):
		var bullet:Dictionary=projectiles[index];var start:Vector3=bullet.position
		bullet.age+=delta;var end:Vector3=start+bullet.velocity*delta;bullet.velocity.y-=9.8*delta
		var bounds:=AABB(start.min(end)-Vector3.ONE*.1,(start-end).abs()+Vector3.ONE*.2)
		var remove:bool=bullet.epoch!=game.terrain.epoch or bullet.age>2 or not game._actor_collision_ready(bounds)
		if not remove:
			var omit:Array=[game.player.get_rid()]
			var solid:Dictionary=game.structures.blocks.raycast_scene(start,end,15,omit,true)
			var zombie:Dictionary=game.zombies.pick(start,end,omit)
			if not zombie.is_empty() and (solid.is_empty() or start.distance_squared_to(zombie.position)<=start.distance_squared_to(solid.position)+.001):
				var before:float=zombie.zombie.health
				if game.zombies.apply_hit(zombie,bullet.damage,bullet.velocity.normalized(),"firearm"):
					var lost:float=before-maxf(0,zombie.zombie.health)
					if lost>0:game.player_hud.award_experience(mini(15,ceili(lost))+(25 if not zombie.zombie.alive else 0))
					game.player_hud.show_target_damage("Zombie · "+str(zombie.part).replace("_"," "),maxi(0,ceili(zombie.zombie.health)),int(zombie.zombie.PARTS.torso.health))
				hits+=1;remove=true
				game.terrain.changed_since_save=true
			elif not solid.is_empty():impact(solid,bullet.velocity.normalized(),bullet.damage,bullet.block_damage);remove=true
		if remove:bullet.view.queue_free();projectiles.remove_at(index);continue
		bullet.position=end;bullet.view.global_position=end
		bullet.view.look_at(end+bullet.velocity.normalized())
func impact(hit:Dictionary,direction:Vector3,damage:int=35,block_damage:int=18)->void:
	hits+=1
	if holes!=null and hit.has("position"):holes.add(hit.position,hit.get("normal",-direction),_surface(hit,direction))
	if hit.get("collider")==barrels:
		damage_barrel(barrels.placement_for_body(hit.rid),damage);return
	if hit.get("collider")==game.structures.blocks and hit.has("cell"):
		var cell:Vector3i=hit.cell;damage_block(cell,game.structures.blocks.get_cell(cell),block_damage,hit.position-direction,3)
## What the bullet hit, so the hole matches the material it landed on.
func _surface(hit:Dictionary,direction:Vector3)->String:
	if hit.get("collider")==game.structures.blocks and hit.has("cell"):
		var word:int=game.structures.blocks.get_cell(hit.cell)
		if word!=0:
			var material:int=game.structures.blocks.decode_block(word).material
			if material==1:return "wood"
			if material>=3:return "metal"
			return "stone"
	var world_audio:Node=game.get_node_or_null("WorldAudio")
	if world_audio!=null and world_audio.has_method("material_at"):
		var sampled:=str(world_audio.material_at(hit.get("position",Vector3.ZERO)))
		if sampled=="rock":return "stone"
		if sampled in ["stone","wood","metal","dirt","grass"]:return sampled
	return "stone"

func holes_path()->String:
	return "user://bullet_holes_%s.json"%game.terrain.save_slot

func _save_holes()->void:
	if holes==null or game==null:return
	var file:=FileAccess.open(holes_path(),FileAccess.WRITE)
	if file==null:return
	file.store_string(JSON.stringify({"schema":1,"revision":game.terrain.native_revision,"rows":holes.encode()}))
	file.close()

func _load_holes()->void:
	if holes==null:return
	holes.clear()
	if not FileAccess.file_exists(holes_path()):return
	var parsed:Variant=JSON.parse_string(FileAccess.get_file_as_string(holes_path()))
	if parsed is Dictionary:holes.decode(parsed.get("rows",[]))

func barrel_position(id:int)->Vector3:
	var pose:PackedFloat32Array=barrels.get_instance(id)
	return barrels.to_global(Vector3(pose[3],pose[7],pose[11])) if pose.size()==12 else Vector3.INF
func damage_barrel(id:int,damage:int)->bool:
	if id<=0 or not barrel_position(id).is_finite() or barrels.is_removal_protected(id):return false
	var result:Dictionary=game.world_attack.durability.hit("model:%s:%d"%[Barrel.KEY,id],50,damage)
	if not result.ok:return false
	game.terrain.changed_since_save=true
	if result.destroyed and id not in detonations and detonations.size()<256:detonations.append(id)
	return true
func place_barrel()->bool:
	if not can_use() or game.equipped_tool!=Barrel.ITEM or barrels.get_ids().size()>=256:return false
	var start:Vector3=game.camera.global_position
	var hit:Dictionary=game.structures.blocks.raycast_scene(start,start-game.camera.global_basis.z*4,15,[game.player.get_rid()])
	if hit.is_empty() or hit.normal.y<.8:return false
	var point:Vector3=hit.position+Vector3.UP*.02;var bounds:=AABB(point+Barrel.BOUNDS.position,Barrel.BOUNDS.size)
	if not game._placement_collision_ready(bounds) or not game._prefab_player_clear(bounds):return false
	var query:=PhysicsShapeQueryParameters3D.new();var shape:=BoxShape3D.new();shape.size=Barrel.BOUNDS.size*.96;query.shape=shape;query.transform=Transform3D(Basis.IDENTITY,bounds.get_center()+Vector3.UP*.02);query.collision_mask=15
	if not get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():return false
	var records:PackedFloat32Array=game.model_tool.records(Transform3D(Basis.IDENTITY,point),barrels)
	var id:int=game.construction_inventory.place_model(game.model_tool.history,barrels,game.player_hud.inventory,records,AABB(game.player.global_position-Vector3(.4,0,.4),Vector3(.8,1.8,.8)),PackedInt64Array([Barrel.ITEM,1]))
	if id<=0:return false
	game.terrain.changed_since_save=true;game.player_hud.refresh();return true
func damage_block(cell:Vector3i,word:int,damage:int,origin:Vector3,force:float)->bool:
	if word==0 or damage<=0 or game.structures.blocks.get_cell(cell)!=word:return false
	var material:int=game.structures.blocks.decode_block(word).material
	var key:String=game.world_attack.block_key(cell)
	var result:Dictionary=game.world_attack.durability.hit(key,Durability.BLOCK_MAXIMUM[material],damage)
	if not result.ok:return false
	game.terrain.changed_since_save=true
	if result.destroyed:return demolish(cell,word,origin,force)
	return true
func demolish(cell:Vector3i,word:int,origin:Vector3,force:float)->bool:
	if word==0 or game.structures.blocks.get_cell(cell)!=word:return false
	if not game.structures.blocks.set_cells(PackedInt32Array([cell.x,cell.y,cell.z,0])):return false
	game.structures.blocks.clear_history();game.world_attack.durability.forget(game.world_attack.block_key(cell))
	effects.block(cell,word,origin,force);destroyed_blocks+=1;game.terrain.changed_since_save=true;return true
func detonate(id:int)->bool:
	if blast_jobs.size()>=32:return false
	var base:=barrel_position(id)
	if not base.is_finite():return true
	var center:=base+Vector3.UP*.5
	if not game._actor_collision_ready(AABB(center-Vector3.ONE*6,Vector3.ONE*12)):return false
	if barrels.is_removal_protected(id):return true
	# The same native density edit, publication, water, vegetation and save path
	# as mining. The environmental admission does not pay mining rewards.
	if not game.mining_rewards.excavate_blast(base+Vector3.UP*.2,3.5):return false
	if not barrels.remove_instances(PackedInt64Array([id])):return false
	game.model_tool.history.clear_history();game.world_attack.durability.forget("model:%s:%d"%[Barrel.KEY,id])
	var origin:=Vector3i((center-Vector3.ONE*5).floor())
	var prefab:Resource=game.structures.blocks.capture_prefab(origin,Vector3i(12,12,12))
	if prefab!=null:blast_jobs.append({"records":state.blast_cells(prefab.get_records(),origin,center,5.0),"offset":0,"center":center})
	for other:int in barrels.get_ids():
		var point:=barrel_position(other)+Vector3.UP*.5
		if point.is_finite() and point.distance_squared_to(center)<36:damage_barrel(other,50)
	for zombie:Node3D in game.zombies.residents.duplicate():
		var point:=zombie.global_position+Vector3.UP*.9;var distance:=point.distance_to(center)
		if distance>7:continue
		var direction:Vector3=(point-center).normalized()
		game.zombies.apply_hit({"zombie":zombie,"part":"torso","position":point},maxf(1,180*(1-distance/7)),direction,"heavy")
	var distance:float=game.player.global_position.distance_to(center)
	if distance<7:
		var damage:=80*(1-distance/7)
		game.zombie_target.receive_zombie_attack(damage);game._show_lake_notice("Blast hit · %d damage"%roundi(damage))
	effects.explosion(center);play_sound(center,blast_audio);game.zombies.hear_noise(center,96)
	explosions+=1;game.terrain.changed_since_save=true;return true
func step_blasts()->void:
	if blast_jobs.is_empty():return
	var job:Dictionary=blast_jobs[0];var records:PackedInt32Array=job.records
	for _i in 24:
		if job.offset>=records.size():blast_jobs.pop_front();break
		var at:int=job.offset;job.offset+=4
		var cell:=Vector3i(records[at],records[at+1],records[at+2])
		var distance:float=(Vector3(cell)+Vector3.ONE*.5).distance_to(job.center)
		damage_block(cell,records[at+3],maxi(1,roundi(300*(1-distance/5))),job.center,9*(1-distance/6))
func clear_transients()->void:
	for bullet in projectiles:bullet.view.queue_free()
	projectiles.clear();detonations.clear();blast_jobs.clear();effects.clear()
func _physics_process(delta:float)->void:
	if game==null:return
	if epoch!=game.terrain.epoch:
		epoch=game.terrain.epoch;clear_transients();cancel_reload();integrity.reset()
		restored_support_pending=true
	var running:=active();effects.step(delta,running)
	if ammo_label!=null:ammo_label.visible=running and game.equipped_tool in WEAPONS
	game.tool_view.human.rifle_aiming=can_use() and game.equipped_tool in WEAPONS and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if reload_slot>=0 and (not can_use() or game.equipped_tool!=reload_weapon or game.player_hud.active_slot!=reload_slot):cancel_reload()
	if not running:return
	if restored_support_pending:
		restored_support_pending=false
		if state.integrity_enabled():integrity.changed(AABB(game.player.global_position-Vector3.ONE,Vector3.ONE*2))
	timer+=delta;step_projectiles(minf(delta,.05));step_blasts()
	if not game.terrain.pending_edit and not detonations.is_empty() and detonate(detonations[0]):detonations.pop_front()
	if blast_jobs.is_empty():integrity.step()
	# Reconstruct ignited barrels after save/load from their native durability.
	if int(timer)!=int(timer-delta):
		for id:int in barrels.get_ids():
			if game.world_attack.durability.damage("model:%s:%d"%[Barrel.KEY,id],50)>=50 and id not in detonations and detonations.size()<256:detonations.append(id)
	if game.equipped_tool in WEAPONS and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):fire()
	if ammo_label==null and game.player_hud.action_hint!=null:
		ammo_label=Label.new();ammo_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT;ammo_label.custom_minimum_size.x=340;ammo_label.add_theme_font_size_override("font_size",22);game.player_hud.add_child(ammo_label)
	if ammo_label!=null:
		ammo_label.visible=game.equipped_tool in WEAPONS and not game.player_hud.inventory_open and not game.session_menu.visible_ui()
		var viewport_size:Vector2=get_viewport().get_visible_rect().size
		ammo_label.text="%s  %02d / 30   ·   %d reserve%s"%[WEAPONS.get(game.equipped_tool,WEAPONS[RIFLE]).title,state.get_rounds(game.equipped_tool),rounds_in_bag(),"   RELOADING" if reload_slot>=0 else ""]
		ammo_label.size=ammo_label.get_combined_minimum_size()
		ammo_label.position=Vector2(maxf(24,viewport_size.x-ammo_label.size.x-30),maxf(24,viewport_size.y-210))
func sound(duration:float,frequency:float)->AudioStreamWAV:
	var stream:=AudioStreamWAV.new();stream.format=AudioStreamWAV.FORMAT_16_BITS;stream.mix_rate=22050
	var data:=PackedByteArray();data.resize(int(duration*22050)*2);var random:=RandomNumberGenerator.new();random.seed=57
	for index in data.size()/2:
		var t:float=index/22050.0;var envelope:=pow(1-t/duration,3)
		var sample:float=(random.randf_range(-1,1)*.65+sin(t*TAU*frequency)*.35)*envelope*.6
		data.encode_s16(index*2,int(sample*32767))
	stream.data=data;return stream
func play_sound(point:Vector3,stream:AudioStreamWAV)->void:
	var player:AudioStreamPlayer3D
	for candidate in audio_pool:
		if not candidate.playing:player=candidate;break
	if player==null:
		if audio_pool.size()>=8:return
		player=AudioStreamPlayer3D.new();player.max_distance=96;add_child(player);audio_pool.append(player)
	player.global_position=point;player.stream=stream;player.play()
