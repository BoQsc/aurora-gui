# SPDX-License-Identifier: 0BSD
extends RefCounted
# Bounded interaction adapter. Native stores own damage, inventories and geometry.
var game: Node
var durability: RefCounted
var next_attack:=0
var rejection_reason:=""
var sequence:=0
var pending:Dictionary={}
var queued_click:=false
var last_hit:=false
signal impact_resolved(identity:int,accepted:bool)
signal impact_preparing(from:Vector3,to:Vector3)
signal contact_effect(target:Dictionary)
const Durability=preload("res://addons/player_runtime/durability_catalog.gd")
const Progression=preload("res://addons/player_runtime/progression_rules.gd")
const TOOLS={0:{"stone":5,"wood":5,"other":5},1:{"stone":30,"wood":10,"other":15},2:{"stone":10,"wood":30,"other":15},3:{"stone":15,"wood":15,"other":20},4:{"stone":10,"wood":15,"other":15},5:{"stone":15,"wood":5,"other":10},6:{"stone":5,"wood":5,"other":10}}
const ZOMBIE_IMPACTS={0:"unarmed",1:"melee",2:"cutting",3:"melee",4:"melee",5:"melee",6:"melee"}
const BARE_HAND_REACH := 1.65
func reach() -> float:return BARE_HAND_REACH if game.equipped_tool==0 else 3.5
func prepare(world: Node) -> bool:
	game=world;durability=ClassDB.instantiate("NativeWorldDurability")
	game.tool_view.attack_allowed=can_continue
	game.tool_view.attack_contact.connect(resolve_contact)
	game.tool_view.attack_finished.connect(finish_swing)
	return game.persistence.register_component("world_durability",durability.capture_storage_snapshot,durability.restore_storage_snapshot,durability,durability.capture_storage_snapshot())
func block_key(cell: Vector3i) -> String:return "block:%d:%d:%d"%[cell.x,cell.y,cell.z]
func target() -> Dictionary:
	var start: Vector3=game.camera.global_position
	var end: Vector3=start-game.camera.global_basis.z*reach()
	var hit: Dictionary=game.structures.blocks.raycast_scene(start,end,0xFFFFFFFF,[game.player.get_rid()])
	var zombie_hit: Dictionary=game.zombies.pick(start,end,[game.player.get_rid()])
	var same_zombie:bool=not zombie_hit.is_empty() and not hit.is_empty() and (hit.get("collider")==zombie_hit.zombie or (hit.get("collider")!=null and hit.collider.get_meta("zombie",null)==zombie_hit.zombie))
	if not zombie_hit.is_empty() and (hit.is_empty() or same_zombie or start.distance_squared_to(zombie_hit.position)<=start.distance_squared_to(hit.position)+0.001):
		return zombie_hit
	if game.ground_enabled and game.ground_interaction.available():
		var candidate:Dictionary=game.ground_interaction.collection_probe(start,end,hit)
		if candidate.get("blocked",false):return {}
		if candidate.ok:
			var cover:Dictionary=candidate.hit
			return surface_target({"kind":"cover","key":"cover:%d"%cover.id,"id":cover.id,"cell":cover.cell,"cover_owner":candidate.owner,"species":cover.species,"large":cover.get("large",false),"health":240 if cover.get("large",false) else Durability.COVER_MAXIMUM[cover.species],"material":"stone" if cover.species==0 else "wood","name":"Stone boulder" if cover.get("large",false) else game.player_hud.GroundCatalog.NAMES[cover.species],"end":end},cover)
	if hit.is_empty():
		if game.terrain.backend.region_terrain:hit=game._terrain_pick(start,end)
		if hit.is_empty():return {}
	var collider=hit.get("collider")
	if collider==game.structures.blocks and hit.has("cell"):
		var cell: Vector3i=hit.cell
		var word: int=game.structures.blocks.get_cell(cell)
		var material_id: int=game.structures.blocks.decode_block(word).material
		return surface_target({"kind":"block","key":block_key(cell),"health":Durability.BLOCK_MAXIMUM[material_id],"material":"wood" if material_id==1 else "stone","material_id":material_id,"name":"Building block","cell":cell},hit)
	if collider!=null and collider==game.vegetation.trunk_collision:
		var id: int=collider.placement_for_body(hit.rid)
		if id>0:return surface_target({"kind":"tree","key":"tree:%d"%id,"id":id,"health":Durability.WORLD.tree,"material":"wood","name":"Tree"},hit)
	for asset: String in game.structures._models:
		var collection=game.structures._models[asset]
		if collider==collection:
			var id: int=collection.placement_for_body(hit.rid)
			var profile:Dictionary=Durability.model_profile(asset,game.structures.object_definitions)
			if id>0:return surface_target({"kind":"model","key":"model:%s:%d"%[asset,id],"id":id,"collection":collection,"asset":asset,"health":profile.health,"material":profile.material,"impact_material":profile.get("impact_material",""),"name":profile.name},hit)
	if collider!=null and game.actors.pool!=null and collider.get_parent()==game.actors.pool:
		var handle: int=collider.entity_handle(game.actors.store)
		if handle!=0:
			var id: int=game.actors.store.persistent_id(handle)
			return surface_target({"kind":"actor","key":"actor:%d"%id,"id":id,"handle":handle,"health":Durability.WORLD.actor,"material":"other","name":"Actor"},hit)
	var vehicles=game.world_vehicle
	var vehicle_id: int=vehicles.car_identity if collider!=null and collider==vehicles.car else 0
	if vehicles.fleet_enabled and collider!=null:
		for id: int in vehicles.activation.residents:
			if vehicles.activation.residents[id]==collider:vehicle_id=id
		var parked_id:int=vehicles.activation.parked_identity(collider,hit.rid)
		if parked_id>0:vehicle_id=parked_id
	if vehicle_id>0:
		if vehicles.is_service(vehicle_id):return {} # Reserved NPC service vehicle.
		return surface_target({"kind":"vehicle","key":"vehicle:%d"%vehicle_id,"id":vehicle_id,"health":Durability.WORLD.vehicle,"material":"other","name":"Vehicle"},hit)
	if collider==null or (collider is CollisionObject3D and game.terrain.is_ancestor_of(collider) and collider.collision_layer&1):
		var cell:=Vector3i((hit.position-hit.normal*0.05).floor())
		return {"kind":"terrain","key":"terrain:%d:%d:%d"%[cell.x,cell.y,cell.z],"health":Durability.WORLD.terrain,"material":"stone","name":"Terrain","position":hit.position,"normal":hit.normal}
	return {}
func surface_target(data:Dictionary,hit:Dictionary)->Dictionary:
	var collider=hit.get("collider")
	if is_instance_valid(collider) and collider.has_meta("impact_material"):data.impact_material=collider.get_meta("impact_material")
	if hit.has("position"):
		data.position=hit.position
		data.normal=hit.get("normal",(game.camera.global_position-hit.position).normalized())
	return data
## pressed marks a fresh button press. The held-button poll also calls this every
## frame, so only a press edge may arm the click buffer - otherwise one click
## would queue a second swing.
func attack(repairing:bool=false,pressed:bool=false) -> bool:
	if not pending.is_empty():
		if pressed: queued_click=true
		return false
	if game.session_menu.developer or not TOOLS.has(game.equipped_tool) or not game._model_edit_available() or Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED or game.session_menu.visible_ui():return false
	if repairing and game.equipped_tool!=3:return false
	var now:=Time.get_ticks_msec()
	if now<next_attack:return false
	var profile:Dictionary=game.tool_view.attack_profile()
	if profile.is_empty():return false
	sequence+=1;last_hit=false
	pending={"identity":sequence,"item":game.equipped_tool,"slot":game.player_hud.active_slot,"epoch":game.terrain.epoch,"contacted":false,"repairing":repairing}
	if not game.tool_view.begin_attack(sequence):pending={};return false
	# Recovery is owned by the actual animation; retain the minimum input debounce.
	next_attack=now+250;game.terrain.set_attack_active(true)
	impact_preparing.emit(game.camera.global_position,game.camera.global_position-game.camera.global_basis.z*reach())
	return true
func can_continue()->bool:
	return not pending.is_empty() and not game.session_menu.developer and not game.session_menu.visible_ui() and not game.player_hud.inventory_open and not game.storage.opened and not game.loading_active and not game.shutdown_requested and not game.benchmark_enabled and game.app_focused and not game.world_vehicle.driving and game.terrain.world_ready and game.terrain.epoch==pending.epoch and Input.mouse_mode==Input.MOUSE_MODE_CAPTURED and game.equipped_tool==pending.item and game.player_hud.active_slot==pending.slot
func resolve_contact(identity:int)->void:
	if pending.is_empty() or pending.identity!=identity or pending.contacted:return
	if not game.tool_view.contact_ready(identity):return
	if not can_continue() or not game._model_edit_available():cancel();return
	if pending.item!=0:
		var row:Dictionary=game.player_hud.inventory.snapshot().slots[pending.slot]
		if row.item!=pending.item or row.count<=0:cancel();return
	pending.contacted=true
	# Resolve the live occlusion/reach query once, on the visible contact pose.
	var selected:=target()
	if selected.get("kind")=="terrain":game.terrain.set_interaction_target(selected.position)
	if selected.get("kind")=="terrain":
		var probe: Node=game.get_node_or_null("WorldAudio")
		if probe!=null and probe.has_method("prime_material"):probe.prime_material(selected.get("position",game.camera.global_position))
	last_hit=not selected.is_empty() and (repair_target(selected) if pending.repairing else apply_target(selected))
	if last_hit:
		selected.repairing=pending.repairing
		if is_instance_valid(game.zombies) and game.zombies.has_method("hear_noise"):
			game.zombies.hear_noise(selected.get("position",game.camera.global_position),4.0 if pending.item==0 else 12.0)
		contact_effect.emit(selected)
	impact_resolved.emit(identity,last_hit)
func cancel()->void:
	if pending.is_empty():return
	game.tool_view.cancel_attack()
func finish_swing(identity:int,cancelled:bool)->void:
	if game.tool_view.attack_identity==0:game.terrain.set_attack_active(false)
	if pending.is_empty() or pending.identity!=identity:return
	if cancelled and not pending.contacted:next_attack=0
	pending={}
	if queued_click:
		queued_click=false
		next_attack=0
		attack.call_deferred()
func repair_target(t:Dictionary)->bool:
	if game.equipped_tool!=3 or t.kind not in ["block","model","vehicle"]:return false
	if t.kind=="model" and str(t.get("asset","")).begins_with("resources/"):return false
	var result:Dictionary=durability.repair(t.key,t.health,25)
	if not result.ok:
		game._show_lake_notice(result.get("reason","Repair unavailable"));return false
	var hud=game.player_hud
	hud.inventory.wear_tool(hud.active_slot,1,hud.inventory.snapshot().revision)
	game.terrain.changed_since_save=true;hud.refresh()
	hud.show_target_damage(t.name,result.remaining,result.maximum)
	game._show_lake_notice("Repaired %s · %d / %d durability"%[t.name,result.remaining,result.maximum])
	return true
func harvest_profile(t:Dictionary)->Dictionary:
	if t.kind=="tree" and t.id>0 and t.id<=32*32*game.ecosystem.GRID*game.ecosystem.GRID:return {"item":102,"step":Durability.HARVEST_DAMAGE_PER_ITEM,"final":game.ecosystem.TREE_REWARD}
	if t.kind=="model" and Durability.RESOURCE_MODELS.has(t.get("asset","")):return {"item":Durability.RESOURCE_MODELS[t.asset],"step":Durability.HARVEST_DAMAGE_PER_ITEM,"final":game.material_deposits.REWARD}
	if t.kind=="cover" and t.id>0 and t.id<4294967296:
		if t.species==0:return {"item":201,"step":Durability.HARVEST_DAMAGE_PER_ITEM,"final":game.ground_interaction.LARGE_REWARD if t.get("large",false) else 1}
		if t.species in [7,8]:return {"item":102,"step":1 if t.species==8 else 5,"final":1}
		if t.species>=0 and t.species<game.ground_interaction.Catalog.COUNT:return {"item":game.ground_interaction.Catalog.REWARDS[t.species],"step":Durability.HARVEST_DAMAGE_PER_ITEM,"final":1}
	return {}
func apply_target(t: Dictionary) -> bool:
	var hud=game.player_hud
	var item: int=game.equipped_tool
	if not TOOLS.has(item) or (item!=0 and hud.active_slot<0):return false
	if t.kind=="terrain":
		# Ask the ground what it is made of before it is gone; the answer is
		# ready by the breaking hit.
		var adapter: Node=game.get_node_or_null("WorldAudio")
		if adapter!=null and adapter.has_method("prime_material"):adapter.prime_material(t.get("position",game.camera.global_position))
	if t.kind=="model" and t.get("asset","")==game.combat.Barrel.KEY:
		if not game.combat.damage_barrel(t.id,TOOLS[item]["other"]):return false
		if item!=0:hud.inventory.wear_tool(hud.active_slot,1,hud.inventory.snapshot().revision)
		hud.refresh();return true
	if t.kind=="zombie":
		var health_before:float=maxf(0,t.zombie.health)
		if not game.zombies.apply_hit(t,hud.skill_damage(Progression.MELEE,TOOLS[item]["other"]),-game.camera.global_basis.z,ZOMBIE_IMPACTS[item]):return false
		var health_lost:float=health_before-maxf(0,t.zombie.health)
		if health_lost>0:hud.award_experience(mini(15,int(ceil(health_lost)))+(25 if not t.zombie.alive else 0))
		var part:String=t.get("part","torso")
		hud.damage_feedback.show_zombie_hit(part.replace("_"," ").capitalize(),int(ceil(t.zombie.health)),int(t.zombie.PARTS.torso.health),float(t.zombie.limb_health.get(part,0.0)),float(t.zombie.PARTS[part].health),t.zombie.missing.get(part,false))
		if item!=0:
			hud.inventory.wear_tool(hud.active_slot,1,hud.inventory.snapshot().revision)
			game.terrain.changed_since_save=true
		hud.refresh()
		game._show_lake_notice("Zombie struck · %d / %d health"%[int(ceil(t.zombie.health)),int(t.zombie.PARTS.torso.health)] if t.zombie.alive else "Zombie down")
		return true
	if t.kind=="actor" and (t.handle==0 or game.actors.store.resolve_identity(t.id)!=t.handle):return false
	if t.kind=="tree" and (not game.vegetation.renderer.roots.has(t.id) or game.ecosystem.harvest_state.contains(t.id)):return false
	if t.kind=="cover":
		var owner:Node=t.get("cover_owner",game.ground_cover)
		if not is_instance_valid(owner) or not owner.owner_available(t.cell):return false
		var rows:Array=owner.resident[t.cell]
		if t.species<0 or t.species>=rows.size() or not rows[t.species].ids.has(t.id):return false
	if t.kind=="model" and Durability.RESOURCE_MODELS.has(t.get("asset","")) and t.collection.get_instance(t.id).is_empty():return false
	var locked:bool=t.kind=="model" and t.collection==game.storage.collection and game.storage.store.is_locked(t.id)
	var door_lock:RefCounted=game.doors.lock_for(t.collection,t.id) if t.kind=="model" and game.get("doors")!=null else null
	if t.kind=="model" and t.collection.is_removal_protected(t.id) and not locked:
		game._show_lake_notice("Empty stored contents before damaging this container");return false
	var damage:int=30 if item==5 and t.kind=="terrain" else TOOLS[item][t.material]
	if t.kind=="cover" and t.get("species",-1)==8:damage=1
	var harvest:=harvest_profile(t);var before:Dictionary={};var result:Dictionary
	if t.kind=="terrain" or not harvest.is_empty():
		damage=hud.skill_damage(Progression.MINING if t.material=="stone" else Progression.WOODCRAFT,damage)
	if door_lock!=null:
		if t.collection.get_instance(t.id).is_empty():return false
		result=door_lock.damage(t.id,damage);result["destroyed"]=false;t.name="Door reinforcement"
	elif locked:
		if t.collection.get_instance(t.id).is_empty():return false
		result=game.storage.store.damage_lock(t.id,damage,game.storage.store.lock_state(t.id).store_revision)
		result["destroyed"]=false
		if result.ok:game.storage.protect(t.id,game.storage.store.requires_protection(t.id))
		t.name="Chest lock"
	elif not harvest.is_empty():
		before=hud.inventory.snapshot()
		var planned:Dictionary=durability.preview_harvest(t.key,t.health,damage,harvest.step,Durability.HARVEST_FINISHING_BONUS)
		if not planned.ok:game._show_lake_notice(planned.get("reason","Harvest unavailable"));return false
		if planned.destroyed and not hud.inventory.can_receive(PackedInt64Array([harvest.item,planned.reward_count+harvest.final]),before.revision).ok:
			game._show_lake_notice("Make room in inventory for the finishing harvest");return false
		result=durability.harvest_hit(t.key,t.health,damage,harvest.item,harvest.step,Durability.HARVEST_FINISHING_BONUS,hud.inventory,before.revision)
	else:result=durability.hit(t.key,t.health,damage)
	if not result.ok:game._show_lake_notice(result.get("reason","Damage unavailable"));return false
	game.terrain.changed_since_save=true
	rejection_reason=""
	var accepted:=true
	if result.destroyed:accepted=destroy(t)
	if not accepted:
		if not harvest.is_empty():
			if result.applied>0:durability.repair(t.key,t.health,result.applied)
			if result.reward_count>0 and not hud.inventory.restore(before,hud.inventory.snapshot().revision).ok:push_error("Harvest reward rollback failed")
		game._show_lake_notice(rejection_reason if not rejection_reason.is_empty() else "Destruction blocked; make inventory room or wait for the world");return false
	if not harvest.is_empty() and result.applied>0:
		hud.award_experience(mini(12,int(result.reward_count)*2)+(8 if result.destroyed else 0))
	# Every landed hit sounds, not only the one that destroys the target.
	if accepted and (result.destroyed or int(result.get("applied", 0)) > 0): break_sound(t)
	if t.kind=="cover" and t.get("large",false) and not result.destroyed:game.ground_cover.damage_boulder(t.id,game.camera.global_position)
	hud.show_target_damage(t.name,int(result.remaining),int(result.maximum))
	t["destroyed"]=result.destroyed
	if result.destroyed:durability.forget(t.key)
	var wear: Dictionary=hud.inventory.wear_tool(hud.active_slot,1,hud.inventory.snapshot().revision) if item!=0 else {}
	hud.refresh()
	game._show_lake_notice((hud.CATALOG.get(item,"Tool")+" broke · Tab → Crafting to make a replacement") if wear.get("broken",false) else (t.name+" destroyed" if result.destroyed else "%s: %d / %d durability"%[t.name,result.remaining,result.maximum]))
	if locked and result.get("opened",false):game._show_lake_notice("Lock broken · E open chest")
	if door_lock!=null and result.get("opened",false):game._show_lake_notice("Reinforcement broken · E open door")
	return true
## Breakage is material specific: stone, wood, metal, dirt and vegetation each
## get their own event so a note written for rock never plays over soil.
func break_event(t: Dictionary) -> String:
	var material := str(t.get("material", ""))
	if str(t.get("surface", "")) == "dirt": return "world.break.dirt"
	match str(t.kind):
		"tree": return "world.break.wood"
		"terrain":
			var surface := str(_sampled_material(t.get("position", Vector3.ZERO)))
			match surface:
				"dirt", "soil": return "world.break.dirt"
				"grass", "leaves", "vegetation": return "world.break.vegetation"
				"wood": return "world.break.wood"
				"metal": return "world.break.metal"
				"rock", "stone": return "world.break.stone"
			match int(game.material_id):
				2: return "world.break.wood"
				3: return "world.break.metal"
			# Untouched ground is topsoil, not rock: stone is only claimed when
			# the sampled surface actually says so.
			return "world.break.dirt"
		"cover":
			return "world.break.stone" if material == "stone" else "world.break.vegetation"
		"block":
			return "world.break.wood" if material == "wood" else "world.break.stone"
	if material == "stone": return "world.break.stone"
	if material == "wood": return "world.break.wood"
	if material == "metal": return "world.break.metal"
	return "world.break.block"

func _sampled_material(point: Vector3) -> String:
	var adapter: Node = game.get_node_or_null("WorldAudio")
	if adapter == null or not adapter.has_method("material_at"): return ""
	return str(adapter.material_at(point))

func break_sound(t: Dictionary, local: bool = true) -> void:
	var audio: Node = game.get_node_or_null("WorldAudio")
	if audio == null or not audio.has_method("play_event"): return
	audio.play_event(break_event(t), t.get("position", game.camera.global_position), local)

func destroy(t: Dictionary) -> bool:
	match t.kind:
		"block":return game.combat.demolish(t.cell,game.structures.blocks.get_cell(t.cell),game.camera.global_position,2.0)
		"tree":return game.ecosystem.harvest_root(t.id,game.player_hud.inventory,-game.camera.global_basis.z).ok
		"model":return game._remove_inventory_model(game.model_tool.history,t.collection,t.id)
		"cover":
			var collected: Dictionary=game.ground_interaction.collect(game.camera.global_position,t.end,game.player_hud.inventory,true,null,t.id)
			rejection_reason=collected.reason;return collected.ok
		"terrain":
			var center: Vector3=t.position-t.normal*0.35
			if not game.stroke_buffer.push_sweep(t.position,center,0.65,game.Codec.CONTACT_MINING_SHAPE,false,game.material_id,false):return false
			game._consume_stroke();return game.terrain.pending_edit
		"actor":
			return game._remove_actor(t.id)
		"vehicle":
			var vehicles=game.world_vehicle
			return vehicles.remove_vehicle(t.id)
	return false
