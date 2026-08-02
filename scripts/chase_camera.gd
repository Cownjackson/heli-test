extends Node3D

## Chase camera rig. Runs top-level so the helicopter's roll and pitch never
## reach the camera — it only tracks position and heading, which is what keeps
## a tilt-to-move aircraft readable.

@export var target_path: NodePath = ^".."
## Higher = camera glued to the machine. Lower = laggier, more speed feel.
@export var position_smoothing: float = 8.0
@export var heading_smoothing: float = 5.0
## Metres the aim point leads the helicopter per m/s of speed.
@export var velocity_lead: float = 0.10
@export var look_height: float = 1.2

var _target: Node3D
var _heading: float = 0.0
var _look_at := Vector3.ZERO


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	set_as_top_level(true)
	# The arm sweeps back through the tail boom's own collision box, which reads
	# as the camera snapping forward at certain attitudes. Exclude the airframe.
	if _target is CollisionObject3D:
		($SpringArm3D as SpringArm3D).add_excluded_object((_target as CollisionObject3D).get_rid())
	if _target:
		_heading = _target_heading()
		global_position = _target.global_position
		global_rotation = Vector3(0.0, _heading, 0.0)
		_look_at = _target.global_position + Vector3.UP * look_height


func _physics_process(delta: float) -> void:
	if not _target:
		return

	# Frame-rate independent exponential smoothing.
	var pos_t := 1.0 - exp(-position_smoothing * delta)
	var head_t := 1.0 - exp(-heading_smoothing * delta)

	_heading = lerp_angle(_heading, _target_heading(), head_t)
	global_position = global_position.lerp(_target.global_position, pos_t)
	global_rotation = Vector3(0.0, _heading, 0.0)

	var velocity := Vector3.ZERO
	if _target is RigidBody3D:
		velocity = (_target as RigidBody3D).linear_velocity
	var aim := _target.global_position + Vector3.UP * look_height + velocity * velocity_lead
	_look_at = _look_at.lerp(aim, pos_t)

	# Before the spring arm has pushed the camera back it can sit directly under
	# the aim point, which makes look_at ambiguous — skip those frames.
	var camera := $SpringArm3D/Camera3D as Camera3D
	var to_target := _look_at - camera.global_position
	if to_target.length_squared() > 0.01 and to_target.normalized().cross(Vector3.UP).length_squared() > 1e-4:
		camera.look_at(_look_at, Vector3.UP)


func _target_heading() -> float:
	return _target.global_basis.get_euler(EULER_ORDER_YXZ).y
