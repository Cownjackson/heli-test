class_name HeliWeapons
extends Node3D

## Paired helicopter guns. One ammo unit fires both barrels at the same aim
## point. Ammunition regenerates one unit at a time rather than reloading a
## whole magazine at once.

signal ammo_changed(current: int, maximum: int)

@export var projectile_scene: PackedScene
@export_range(1, 100, 1) var max_ammo: int = 8
@export_range(0.1, 30.0, 0.1) var reload_seconds_per_round: float = 2.0
@export_range(0.0, 30.0, 0.1) var fire_cooldown: float = 3.0
@export var aim_distance: float = 2000.0
@export var aim_cursor_sensitivity: float = 1.15
@export var aim_cursor_margin: float = 24.0
@export_range(0.1, 3.0, 0.05) var projectile_time_scale: float = 1.0

@onready var _heli := get_parent() as Helicopter
@onready var _muzzles: Array[Marker3D] = [
	$GunLeft/Muzzle,
	$GunRight/Muzzle,
]

var ammo: int = 8
var cooldown_remaining: float = 0.0
var reload_progress: float = 0.0
var aim_position := Vector2.ZERO


func _ready() -> void:
	add_to_group(&"heli_weapons")
	if get_tree().has_meta(&"projectile_time_scale"):
		projectile_time_scale = float(get_tree().get_meta(&"projectile_time_scale"))
	ammo = max_ammo
	center_aim()
	ammo_changed.emit(ammo, max_ammo)


func _process(delta: float) -> void:
	cooldown_remaining = maxf(0.0, cooldown_remaining - delta)

	if ammo >= max_ammo:
		reload_progress = 0.0
		return

	reload_progress += delta
	while reload_progress >= reload_seconds_per_round and ammo < max_ammo:
		reload_progress -= reload_seconds_per_round
		ammo += 1
		ammo_changed.emit(ammo, max_ammo)
	if ammo >= max_ammo:
		reload_progress = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not _heli or not _heli.is_local_authority():
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		move_aim(event.relative)
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed:
		if try_fire():
			get_viewport().set_input_as_handled()


## Returns true only when a volley was actually created.
func try_fire() -> bool:
	if ammo <= 0 or cooldown_remaining > 0.0 or projectile_scene == null:
		return false

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return false

	var aim_point := current_aim_point()

	var projectile_parent: Node = get_tree().current_scene
	if projectile_parent == null:
		projectile_parent = get_tree().root
	for muzzle in _muzzles:
		var projectile = projectile_scene.instantiate()
		projectile_parent.add_child(projectile)
		projectile.global_position = muzzle.global_position
		projectile.launch_guided(aim_point, self, _heli, _heli.linear_velocity)

	ammo -= 1
	cooldown_remaining = fire_cooldown
	ammo_changed.emit(ammo, max_ammo)
	return true


func center_aim() -> void:
	var rect := get_viewport().get_visible_rect()
	aim_position = rect.position + rect.size * 0.5
	_clamp_aim_position()


func move_aim(mouse_delta: Vector2) -> void:
	aim_position += mouse_delta * aim_cursor_sensitivity
	_clamp_aim_position()


func set_projectile_time_scale(value: float) -> void:
	projectile_time_scale = clampf(value, 0.1, 3.0)


func get_projectile_time_scale() -> float:
	return projectile_time_scale


## Reprojects the live virtual cursor every physics frame for guided missiles.
func current_aim_point() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return global_position - global_basis.z * aim_distance
	var ray_origin := camera.project_ray_origin(aim_position)
	return ray_origin + camera.project_ray_normal(aim_position) * aim_distance


func _clamp_aim_position() -> void:
	var rect := get_viewport().get_visible_rect()
	var minimum := rect.position + Vector2.ONE * aim_cursor_margin
	var maximum := rect.position + rect.size - Vector2.ONE * aim_cursor_margin
	aim_position.x = clampf(aim_position.x, minimum.x, maximum.x)
	aim_position.y = clampf(aim_position.y, minimum.y, maximum.y)
