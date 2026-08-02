extends Node3D

## Test level. Scatters blocks purely so there's something to judge speed and
## altitude against — untextured ground gives you no motion cues at all.
##
## Multiplayer note: everything spawned here is static scenery, generated from
## a fixed seed so every peer builds an identical world without syncing it.
## Players get spawned by a MultiplayerSpawner later. For now two instances of
## the same helicopter scene stand in for peers 1 and 2: only peer 1 accepts
## offline input, while peer 2 remains a fully physical weapons target.

@export var obstacle_count: int = 90
@export var field_radius: float = 420.0
@export var world_seed: int = 20260801

@onready var _heli: Helicopter = $Helicopter


func _ready() -> void:
	_build_obstacles()
	_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"reset_heli"):
		_heli.reset()
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
	_heli.input_source.center_stick()
	_heli.weapons.center_aim()


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
