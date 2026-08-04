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

@export_group("Edge yaw (prototype)")
## **Off by default — this is open question 10, not a decision.** When on, the
## aim cursor pushing toward the left or right edge of the screen swings the
## camera that way instead of clamping dead against it, so the pilot can look
## around to find a target rather than flying a search pattern.
##
## The thing to judge while flying it is *not* whether looking around works —
## it does. It is what happens to the cyclic. The stick tilts relative to the
## aircraft's heading, not the camera's, so once the camera is yawed off the
## nose, pushing the stick forward no longer moves you up the screen. That is
## the standard third-person-shooter versus vehicle-camera tension, and it is
## the reason this ships behind a flag instead of turned on.
@export var edge_yaw_enabled: bool = false
## How far out the cursor has to be before it starts pushing, as a fraction of
## the half-width. High enough that ordinary aiming near centre never moves the
## camera; low enough that you do not have to jam the cursor into the corner.
@export_range(0.0, 0.95, 0.01) var edge_yaw_deadzone: float = 0.72
## Camera swing at full push, rad/s. This is an edge-scroll, not a switch: the
## further out the cursor is held, the faster the camera comes round.
@export var edge_yaw_rate: float = 1.7
## How far off the nose the camera may be dragged, degrees each way. Past 90 the
## airframe is flying visibly sideways or backwards on screen.
@export_range(0.0, 179.0, 1.0) var edge_yaw_limit_deg: float = 100.0
## How fast the camera returns to the nose once the cursor leaves the band,
## rad/s. 0 makes the offset persist until the cursor pushes it back, which is
## the other candidate feel — try both.
@export var edge_yaw_return: float = 1.1

var _target: Node3D
var _heading: float = 0.0
var _look_at := Vector3.ZERO
## Camera heading relative to the aircraft's, radians. Always 0 unless the
## edge-yaw prototype is enabled.
var _yaw_offset: float = 0.0


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

	_update_edge_yaw(delta)
	_heading = lerp_angle(_heading, _target_heading() + _yaw_offset, head_t)
	global_position = global_position.lerp(_target.global_position, pos_t)
	global_rotation = Vector3(0.0, _heading, 0.0)

	var velocity := Vector3.ZERO
	if _target is Helicopter:
		# Frozen on clients, so ask for the displayable velocity rather than the
		# body's, or the camera stops leading as soon as you join a session.
		velocity = (_target as Helicopter).current_velocity()
	elif _target is RigidBody3D:
		velocity = (_target as RigidBody3D).linear_velocity
	var aim := _target.global_position + Vector3.UP * look_height + velocity * velocity_lead
	_look_at = _look_at.lerp(aim, pos_t)

	# Before the spring arm has pushed the camera back it can sit directly under
	# the aim point, which makes look_at ambiguous — skip those frames.
	var camera := $SpringArm3D/Camera3D as Camera3D
	var to_target := _look_at - camera.global_position
	if to_target.length_squared() > 0.01 and to_target.normalized().cross(Vector3.UP).length_squared() > 1e-4:
		camera.look_at(_look_at, Vector3.UP)


## Prototype. Reads the local aim cursor, which is why it is gated on owning the
## aircraft: a remote helicopter's rig must never consult this machine's viewport
## — the same rule that keeps `compute_flight()` and remote weapons pure.
func _update_edge_yaw(delta: float) -> void:
	var heli := _target as Helicopter
	if not edge_yaw_enabled or heli == null or not heli.is_local_authority():
		# Snap rather than decay, so toggling the flag mid-flight is a clean A/B
		# rather than a slow drift back that muddies the comparison.
		_yaw_offset = 0.0
		return

	# Annotated rather than inferred: `Helicopter.weapons` is untyped on purpose,
	# so the return type is not knowable at parse time.
	var push: float = heli.weapons.aim_edge_push(edge_yaw_deadzone)
	if is_zero_approx(push):
		_yaw_offset = move_toward(_yaw_offset, 0.0, edge_yaw_return * delta)
	else:
		# Subtract, not add: heading is a rotation about +Y, so a *larger* heading
		# swings the nose left. Pushing the cursor right must look right.
		_yaw_offset -= push * edge_yaw_rate * delta
	var limit := deg_to_rad(edge_yaw_limit_deg)
	_yaw_offset = clampf(_yaw_offset, -limit, limit)


## Called on respawn. The cursor is re-centred at the same moment, so letting the
## offset unwind on its own would spend a second swinging the camera through a
## turn the pilot is no longer in.
func recenter() -> void:
	_yaw_offset = 0.0
	if _target:
		_heading = _target_heading()


func _target_heading() -> float:
	if _target is Helicopter:
		return (_target as Helicopter).level_heading()
	return _target.global_basis.get_euler(EULER_ORDER_YXZ).y
