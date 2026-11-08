# SPDX-License-Identifier: 0BSD
extends Node3D
## Capped pool of bullet-hole quads. One mesh and material per surface keep a
## long firefight cheap; oldest holes are recycled and every hole expires.
## Holes are plain data, so they can be saved with the world and restored.

const LIMIT := 96
const LIFETIME := 24.0
const SURFACES := {
	"stone": {"color": Color(.05, .05, .05, .92), "size": .055},
	"wood": {"color": Color(.22, .13, .05, .92), "size": .05},
	"metal": {"color": Color(.55, .57, .6, .9), "size": .045},
	"dirt": {"color": Color(.16, .1, .06, .92), "size": .06},
	"grass": {"color": Color(.12, .18, .07, .9), "size": .06},
}
var holes: Array[Dictionary] = []
var cursor := 0
## Supplies the live world revision; holes are cleared when geometry changes so
## a demolished block cannot leave its holes floating in the air.
var source: Callable
var revision := -1
var meshes: Dictionary = {}
var materials: Dictionary = {}

func _ready() -> void:
	name = "BulletHoles"
	for surface: String in SURFACES:
		var spec: Dictionary = SURFACES[surface]
		var mesh := QuadMesh.new(); mesh.size = Vector2(spec.size, spec.size); meshes[surface] = mesh
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = spec.color
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		materials[surface] = material
	set_process(true)

func add(point: Vector3, normal: Vector3, surface: String = "stone") -> bool:
	if not point.is_finite() or not normal.is_finite() or normal.length_squared() < .01: return false
	if not meshes.has(surface): surface = "stone"
	var entry: Dictionary
	if holes.size() < LIMIT:
		var fresh := MeshInstance3D.new()
		fresh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(fresh); entry = {"node": fresh, "age": 0.0}; holes.append(entry)
	else:
		entry = holes[cursor]; cursor = (cursor + 1) % LIMIT; entry.age = 0.0
	var node: MeshInstance3D = entry.node
	node.mesh = meshes[surface]; node.material_override = materials[surface]
	entry.surface = surface
	var n := normal.normalized()
	node.global_position = point + n * .012
	# look_at cannot use an up vector parallel to the target on flat ground.
	node.look_at(node.global_position + n, Vector3.FORWARD if absf(n.dot(Vector3.UP)) > .99 else Vector3.UP)
	node.show()
	return true

func clear() -> void:
	for entry in holes: entry.node.queue_free()
	holes.clear(); cursor = 0

## Compact rows: position, normal, surface. Used for saving with the world.
func encode() -> Array:
	var rows := []
	for entry in holes:
		var node: MeshInstance3D = entry.node
		if not node.visible: continue
		var n := node.global_basis.z * -1.0
		var p := node.global_position
		rows.append([[p.x, p.y, p.z], [n.x, n.y, n.z], str(entry.get("surface", "stone"))])
	return rows

func decode(rows: Array) -> void:
	clear()
	for row: Variant in rows:
		if row is Array and row.size() >= 3:
			add(vector_of(row[0]), vector_of(row[1]), str(row[2]))

func vector_of(raw: Variant) -> Vector3:
	if raw is Array and raw.size() >= 3: return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	return Vector3.ZERO

func _process(delta: float) -> void:
	if source.is_valid(): sync(int(source.call()))
	for entry in holes:
		entry.age += delta
		if entry.age >= LIFETIME and entry.node.visible: entry.node.hide()

func sync(current: int) -> void:
	if revision < 0: revision = current; return
	if current == revision: return
	revision = current
	clear()
