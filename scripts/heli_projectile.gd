class_name HeliProjectile
extends Node3D

## Fast, visible tracer fired by the helicopter's paired guns. Collision uses a
## ray between physics positions so the projectile cannot tunnel through thin
## scenery at high speed.

@export var speed: float = 65.0
## Maximum steering speed in radians per second. Limiting it produces a visible
## curved intercept instead of snapping the missile directly onto the cursor.
@export var guidance_turn_rate: float = 0.7
@export var lifetime: float = 15.0
@export var impact_impulse: float = 18.0
@export var ignition_delay: float = 0.6
@export var initial_drop_speed: float = 2.5
@export var drop_acceleration: float = 10.0
@export_flags_3d_physics var collision_mask: int = 1
@export var explosion_scene: PackedScene
@export_range(0.1, 3.0, 0.05) var fallback_time_scale: float = 1.0

## True only offline or on the server. Client replicas render streamed state
## and never run guidance, collision queries, impulses, or lifetime decisions.
var authoritative_simulation: bool = true

@onready var _trail: GPUParticles3D = $Trail
@onready var _sparks: GPUParticles3D = $Sparks

var _velocity := Vector3.ZERO
var _age := 0.0
var _ignition_time := 0.0
var _target_position := Vector3.ZERO
var _ignited := false
var _exploded := false
var _guidance_source: Node
var _exclude: Array[RID] = []
var _net_position := Vector3.ZERO
var _net_rotation := Quaternion.IDENTITY
var _net_velocity := Vector3.ZERO
var _has_net_state := false
var _replica_age := 0.0


func _ready() -> void:
	add_to_group(&"heli_projectile")
	_trail.emitting = false
	_sparks.emitting = false


func launch_guided(
	target_position: Vector3,
	guidance_source: Node,
	shooter: CollisionObject3D = null,
	inherited_velocity := Vector3.ZERO,
) -> void:
	_target_position = target_position
	_guidance_source = guidance_source
	_velocity = inherited_velocity + Vector3.DOWN * initial_drop_speed
	if shooter:
		_exclude.append(shooter.get_rid())


func _physics_process(delta: float) -> void:
	if not authoritative_simulation:
		_replica_age += delta * fallback_time_scale
		if _replica_age > lifetime + 5.0:
			queue_free()
			return
		_interpolate_network_state(delta)
		return

	var time_scale := _effective_time_scale()
	_trail.speed_scale = time_scale
	_sparks.speed_scale = time_scale
	var scaled_delta := delta * time_scale
	_age += scaled_delta
	if _age >= lifetime:
		_explode(global_position)
		return

	if not _ignited:
		_ignition_time += scaled_delta
		_velocity += Vector3.DOWN * drop_acceleration * scaled_delta
		if _ignition_time >= ignition_delay:
			_ignite()
	else:
		_steer_toward_cursor(scaled_delta)

	var next_position := global_position + _velocity * scaled_delta
	var query := PhysicsRayQueryParameters3D.create(global_position, next_position)
	query.collision_mask = collision_mask
	query.exclude = _exclude
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		global_position = hit.position
		var collider := hit.collider as RigidBody3D
		if collider:
			collider.apply_central_impulse(_velocity.normalized() * impact_impulse)
		_explode(hit.position)
		return

	global_position = next_position
	_broadcast_network_state()


func _broadcast_network_state() -> void:
	if NetworkSession.is_active() and multiplayer.is_server():
		_receive_network_state.rpc(
			global_position,
			Quaternion(global_basis.orthonormalized()),
			_velocity,
			_ignited,
		)


@rpc("authority", "unreliable_ordered")
func _receive_network_state(
	net_position: Vector3,
	net_rotation: Quaternion,
	net_velocity: Vector3,
	net_ignited: bool,
) -> void:
	if authoritative_simulation:
		return
	_net_position = net_position
	_net_rotation = net_rotation
	_net_velocity = net_velocity
	_has_net_state = true
	_trail.emitting = net_ignited
	_sparks.emitting = net_ignited


func _interpolate_network_state(delta: float) -> void:
	if not _has_net_state:
		return
	_net_position += _net_velocity * delta
	var t := 1.0 - exp(-25.0 * delta)
	global_position = global_position.lerp(_net_position, t)
	var current := Quaternion(global_basis.orthonormalized())
	global_basis = Basis(current.slerp(_net_rotation, t))


func _ignite() -> void:
	_ignited = true
	_refresh_guidance_target()
	var travel_direction := (_target_position - global_position).normalized()
	_velocity = travel_direction * speed
	_trail.emitting = true
	_sparks.emitting = true
	_face_direction(travel_direction)


func _steer_toward_cursor(delta: float) -> void:
	_refresh_guidance_target()
	var desired_direction := (_target_position - global_position).normalized()
	var current_direction := _velocity.normalized()
	if desired_direction.length_squared() < 1e-4 or current_direction.length_squared() < 1e-4:
		return
	var angle := current_direction.angle_to(desired_direction)
	if angle > 1e-4:
		var blend := minf(1.0, guidance_turn_rate * delta / angle)
		current_direction = current_direction.slerp(desired_direction, blend).normalized()
	_velocity = current_direction * speed
	_face_direction(current_direction)


func _refresh_guidance_target() -> void:
	# is_instance_valid() alone is not enough now that helicopters despawn: a
	# launcher detached this frame is still "valid" but no longer belongs to a
	# live aircraft. Keep flying toward the last known target in that case.
	if is_instance_valid(_guidance_source) \
			and _guidance_source.is_inside_tree() \
			and _guidance_source.has_method(&"current_aim_point"):
		_target_position = _guidance_source.current_aim_point()


func _effective_time_scale() -> float:
	if is_instance_valid(_guidance_source) \
			and _guidance_source.has_method(&"get_projectile_time_scale"):
		return float(_guidance_source.get_projectile_time_scale())
	return fallback_time_scale


func _face_direction(direction: Vector3) -> void:
	if direction.length_squared() > 1e-4 \
			and absf(direction.dot(Vector3.UP)) < 0.999:
		look_at(global_position + direction, Vector3.UP)


func _explode(position: Vector3) -> void:
	if _exploded:
		return
	if NetworkSession.is_active() and multiplayer.is_server():
		_explode_replica.rpc(position, _effective_time_scale())
	_finish_explosion(position, _effective_time_scale())


@rpc("authority", "reliable")
func _explode_replica(position: Vector3, time_scale: float) -> void:
	_finish_explosion(position, time_scale)


func _finish_explosion(position: Vector3, time_scale: float) -> void:
	if _exploded:
		return
	_exploded = true
	if explosion_scene:
		var explosion = explosion_scene.instantiate()
		explosion.time_scale = time_scale
		var explosion_parent: Node = get_tree().current_scene
		if explosion_parent == null:
			explosion_parent = get_tree().root
		explosion_parent.add_child(explosion)
		explosion.global_position = position
	queue_free()
