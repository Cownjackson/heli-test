class_name HeliWeapons
extends Node3D

## Paired helicopter guns. One ammo unit fires both barrels at the same aim
## point. Ammunition regenerates one unit at a time rather than reloading a
## whole magazine at once.

signal ammo_changed(current: int, maximum: int)

const WEAPON_STATE_INTERVAL := 0.1

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
var _volley_sequence := 0
var _state_sync_elapsed := 0.0


func _ready() -> void:
	add_to_group(&"heli_weapons")
	if get_tree().has_meta(&"projectile_time_scale"):
		projectile_time_scale = float(get_tree().get_meta(&"projectile_time_scale"))
	ammo = max_ammo
	center_aim()
	ammo_changed.emit(ammo, max_ammo)


func _process(delta: float) -> void:
	if not _owns_weapon_state():
		return

	cooldown_remaining = maxf(0.0, cooldown_remaining - delta)

	if ammo >= max_ammo:
		reload_progress = 0.0
	else:
		reload_progress += delta
		while reload_progress >= reload_seconds_per_round and ammo < max_ammo:
			reload_progress -= reload_seconds_per_round
			ammo += 1
			ammo_changed.emit(ammo, max_ammo)
		if ammo >= max_ammo:
			reload_progress = 0.0

	if _heli.is_networked():
		_state_sync_elapsed += delta
		if _state_sync_elapsed >= WEAPON_STATE_INTERVAL:
			_state_sync_elapsed = 0.0
			_broadcast_weapon_state()


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
		if request_fire():
			get_viewport().set_input_as_handled()


## Requests one paired volley. Offline and host players execute immediately;
## clients ask the server, which validates ownership, ammo, and cooldown.
func request_fire() -> bool:
	if ammo <= 0 or cooldown_remaining > 0.0 or projectile_scene == null:
		return false
	if not _heli.is_networked() or multiplayer.is_server():
		return try_fire()
	_request_fire.rpc_id(1)
	return true


@rpc("any_peer", "reliable")
func _request_fire() -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != _heli.peer_id:
		return
	try_fire()


## Returns true only when a volley was actually created.
func try_fire() -> bool:
	if not _owns_weapon_state():
		return false
	if ammo <= 0 or cooldown_remaining > 0.0 or projectile_scene == null:
		return false

	var aim_point := current_aim_point()
	var muzzle_positions := PackedVector3Array()
	for muzzle in _muzzles:
		muzzle_positions.append(muzzle.global_position)
	_volley_sequence += 1
	if _heli.is_networked():
		_spawn_volley.rpc(
			_volley_sequence,
			muzzle_positions,
			aim_point,
			_heli.current_velocity(),
			projectile_time_scale,
		)
	else:
		_spawn_volley(
			_volley_sequence,
			muzzle_positions,
			aim_point,
			_heli.current_velocity(),
			projectile_time_scale,
		)

	ammo -= 1
	cooldown_remaining = fire_cooldown
	ammo_changed.emit(ammo, max_ammo)
	_broadcast_weapon_state()
	return true


## Server -> everyone. All peers build identical projectile paths so the
## authoritative projectile can stream state through its own RPC methods.
@rpc("authority", "call_local", "reliable")
func _spawn_volley(
	volley_id: int,
	muzzle_positions: PackedVector3Array,
	target_position: Vector3,
	inherited_velocity: Vector3,
	time_scale: float,
) -> void:
	var projectile_parent := _projectile_parent()
	var authoritative := not _heli.is_networked() or multiplayer.is_server()
	for barrel_index in muzzle_positions.size():
		var projectile := projectile_scene.instantiate() as HeliProjectile
		if projectile == null:
			continue
		projectile.name = "Projectile_%d_%d_%d" % [
			_heli.peer_id,
			volley_id,
			barrel_index,
		]
		projectile.authoritative_simulation = authoritative
		projectile.fallback_time_scale = time_scale
		# Volley identity, so a target can tell both barrels of one shot from
		# two unrelated hits and pay the double-hit bonus for the former.
		projectile.shooter_peer_id = _heli.peer_id
		projectile.volley_id = volley_id
		projectile_parent.add_child(projectile)
		projectile.global_position = muzzle_positions[barrel_index]
		projectile.launch_guided(
			target_position,
			self if authoritative else null,
			_heli if authoritative else null,
			inherited_velocity,
		)


func _projectile_parent() -> Node:
	var current_scene := get_tree().current_scene
	if current_scene != null:
		var projectiles := current_scene.get_node_or_null(NodePath("Projectiles"))
		if projectiles != null:
			return projectiles
		return current_scene
	return get_tree().root


func _owns_weapon_state() -> bool:
	return not _heli.is_networked() or multiplayer.is_server()


func _broadcast_weapon_state() -> void:
	if _heli.is_networked() and multiplayer.is_server():
		_receive_weapon_state.rpc(ammo, cooldown_remaining, reload_progress)


@rpc("authority", "unreliable_ordered")
func _receive_weapon_state(
	net_ammo: int,
	net_cooldown: float,
	net_reload_progress: float,
) -> void:
	var ammo_changed_value := ammo != net_ammo
	ammo = net_ammo
	cooldown_remaining = maxf(0.0, net_cooldown)
	reload_progress = maxf(0.0, net_reload_progress)
	if ammo_changed_value:
		ammo_changed.emit(ammo, max_ammo)


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


## The only camera-dependent part of aiming. Called solely by the locally-owned
## helicopter, which stores the result in HeliInput for local and remote weapon
## simulation alike.
func resolve_local_aim_point() -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return forward_aim_point()
	var ray_origin := camera.project_ray_origin(aim_position)
	return ray_origin + camera.project_ray_normal(aim_position) * aim_distance


## Camera-independent guidance value. Remote weapons and projectiles must use
## this path rather than consulting their local viewport.
func current_aim_point() -> Vector3:
	return _heli.control.aim_point if _heli != null else forward_aim_point()


func forward_aim_point() -> Vector3:
	return global_position - global_basis.z * aim_distance


func _clamp_aim_position() -> void:
	var rect := get_viewport().get_visible_rect()
	var minimum := rect.position + Vector2.ONE * aim_cursor_margin
	var maximum := rect.position + rect.size - Vector2.ONE * aim_cursor_margin
	aim_position.x = clampf(aim_position.x, minimum.x, maximum.x)
	aim_position.y = clampf(aim_position.y, minimum.y, maximum.y)
