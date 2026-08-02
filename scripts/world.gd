extends Node3D

## Test level. Scatters blocks purely so there's something to judge speed and
## altitude against — untextured ground gives you no motion cues at all.
##
## Multiplayer note: everything spawned here is static scenery, generated from
## a fixed seed so every peer builds an identical world without syncing it.
##
## Helicopters are *spawned*, not placed in the scene. Nothing may hold a fixed
## path to one — there is no longer a node called "Helicopter", and which
## aircraft belongs to this machine is only known at runtime. Use
## `Helicopter.find_local()`.

## Peer id that owns the aircraft when there is no network. Matches what
## `multiplayer.get_unique_id()` reports offline, so one rule covers both cases.
const OFFLINE_PEER := 1

const SPAWN_HEIGHT := 25.0
const SPAWN_RING := 35.0

@export var obstacle_count: int = 90
@export var field_radius: float = 420.0
@export var world_seed: int = 20260801

@export_group("Players")
@export var helicopter_scene: PackedScene
## Spawns a second, unowned helicopter as a stationary target. Purely a
## development aid for weapons work; it is not a player and never accepts input.
@export var spawn_test_target: bool = true

@onready var _players: Node3D = $Players

## Cached only as an optimisation. Always go through _local_heli(), which
## re-resolves if the aircraft was despawned or ownership changed.
var _heli: Helicopter


func _ready() -> void:
	_build_obstacles()
	spawn_helicopter(OFFLINE_PEER)
	if spawn_test_target:
		spawn_helicopter(OFFLINE_PEER + 1)
	_capture_mouse()


## Creates one aircraft and hands it to `for_peer`.
##
## Ownership is decided before the node enters the tree on purpose: the
## helicopter's `_ready()` reads it to enable its input source and to pick which
## camera becomes current, and neither can be un-done cleanly afterwards.
func spawn_helicopter(for_peer: int) -> Helicopter:
	if helicopter_scene == null:
		push_error("world.gd: helicopter_scene is not set, cannot spawn players.")
		return null

	var heli := helicopter_scene.instantiate() as Helicopter
	heli.name = "Helicopter%d" % for_peer
	heli.peer_id = for_peer
	# Offline there is no get_unique_id() to compare against, so mirror the same
	# rule by hand rather than letting the flag default every aircraft to local.
	heli.offline_local_control = for_peer == OFFLINE_PEER
	heli.transform = spawn_transform_for(_players.get_child_count())
	_players.add_child(heli)
	return heli


## Deterministic spawn placement: index 0 gets the pad, everyone else is spread
## around it facing in. Computed from the index rather than stored in the scene
## so every peer agrees without syncing spawn points.
func spawn_transform_for(index: int) -> Transform3D:
	var origin := Vector3(0.0, SPAWN_HEIGHT, 0.0)
	if index <= 0:
		return Transform3D(Basis.IDENTITY, origin)
	var angle := TAU * float(index - 1) / 6.0
	# Yaw equal to the ring angle points the nose back at the pad.
	return Transform3D(
		Basis.from_euler(Vector3(0.0, angle, 0.0)),
		origin + Vector3(sin(angle), 0.0, cos(angle)) * SPAWN_RING,
	)


func _local_heli() -> Helicopter:
	if not is_instance_valid(_heli) or not _heli.is_local_authority():
		_heli = Helicopter.find_local(get_tree())
	return _heli


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"reset_heli"):
		var heli := _local_heli()
		if heli:
			heli.reset()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_mouse"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			_capture_mouse()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_capture_mouse()


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var heli := _local_heli()
	if heli == null:
		return
	heli.input_source.center_stick()
	heli.weapons.center_aim()


func _build_obstacles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.44, 0.47)
	material.roughness = 0.9

	var parent := Node3D.new()
	parent.name = "Obstacles"
	add_child(parent)

	for i in obstacle_count:
		# Bias away from the spawn pad so you're not boxed in at startup.
		var angle := rng.randf() * TAU
		var distance := lerpf(45.0, field_radius, sqrt(rng.randf()))
		var height := rng.randf_range(12.0, 95.0)
		var width := rng.randf_range(8.0, 22.0)
		var depth := rng.randf_range(8.0, 22.0)
		var size := Vector3(width, height, depth)

		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		mesh.material_override = material

		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape

		var body := StaticBody3D.new()
		body.position = Vector3(cos(angle) * distance, height * 0.5, sin(angle) * distance)
		body.rotation.y = rng.randf() * TAU
		body.add_child(mesh)
		body.add_child(shape)
		parent.add_child(body)
