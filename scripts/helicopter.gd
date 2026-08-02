class_name Helicopter
extends RigidBody3D

## Arcade-lite helicopter that still obeys helicopter rules.
##
## The rules we hold to:
##
## 1. Collective sets the *magnitude* of rotor thrust, and it is an absolute
##    lever position you manage rather than a spring-centred rate. The cyclic
##    only tilts the disc, redirecting that thrust, so vertical lift is
##    T*cos(tilt) and banking costs you altitude unless you feed in collective.
##    This is the coupling that makes a helicopter feel like a helicopter
##    rather than a submarine, and `lift_compensation` cheats on it.
## 2. The fuselage is streamlined nose-on and a barn door sideways, so drag is
##    per-axis in the body frame, not one world-space scalar.
## 3. Translational lift: above roughly 12 m/s the disc bites cleaner air and
##    makes more lift for the same collective, so you balloon slightly as you
##    accelerate out of a hover.
## 4. Main rotor torque coupling is available as a tuning option, but defaults
##    off so neutral pedals hold heading instead of producing input-free drift.
##
## What we deliberately do *not* model: retreating blade stall, vortex ring
## state, autorotation, ground effect, translational lift falling off again at
## high speed. Arcade first.
##
## Multiplayer shape: compute_flight() is a pure function of body state and a
## HeliInput, and reads nothing from the physics engine, so it can move onto a
## custom integrator for prediction/reconciliation unchanged. Whoever fills in
## `control` (local input now, the network later) decides who is flying;
## is_local_authority() is the single gate.

## Emitted on the machine that owns this helicopter when it is written off.
signal crashed

@export_group("Multiplayer")
## Peer that owns this helicopter. 1 is the host / the only player offline.
@export var peer_id: int = 1

@export_group("Physics")
## Ours, not the engine's — gravity_scale is zeroed and we apply this instead,
## so the model behaves identically under a custom integrator later.
@export var gravity: float = 9.8

@export_group("Rotor")
## Thrust-to-weight at full collective. This is the aircraft's power margin and
## it sets everything vertical: hover sits at 1/this on the lever (1.7 => 59%),
## full lever climbs at (this - 1) g, and a closed lever means zero thrust and
## a genuine fall. The lever is a *position* the pilot manages, so holding
## altitude is a thing you fly rather than the default state.
@export_range(1.05, 4.0, 0.01) var max_thrust_ratio: float = 1.7
## How much we cheat rule 1. 0 = honest: tilt redirects a fixed thrust and you
## sink. 1 = arcade: vertical lift is held at hover no matter how far you bank.
@export_range(0.0, 1.0, 0.01) var lift_compensation: float = 0.15
## Floor on the uprightness divisor, so inverted attitudes stay finite.
@export_range(0.05, 1.0, 0.01) var min_uprightness: float = 0.25
## Extra lift once translational lift is fully developed, as a fraction.
@export_range(0.0, 0.5, 0.01) var translational_lift: float = 0.06
## Horizontal airspeed at which that extra lift is fully in, m/s.
@export var translational_lift_speed: float = 12.0

@export_group("Drag")
## Body-frame drag on the horizontal axes, 1/s. Nose-on is slippery, broadside
## is a barn door — that difference is what stops sideways flight feeling free.
## drag_forward sets top speed, roughly tan(max_pitch) * g / this.
@export var drag_forward: float = 0.16
@export var drag_side: float = 0.55
## Climb/sink damping, 1/s, in *world* space rather than body space. Kept out of
## the body frame on purpose: a nose-down attitude puts a large slice of cruise
## velocity on the body's vertical axis, so a body-frame term there reads as
## speed-proportional anti-lift and makes climb rate impossible to tune.
@export var vertical_drag: float = 0.49

@export_group("Attitude")
## Full-stick tilt limits. Deliberately past vertical in every direction: at
## full deflection you commit to going over, then reverse the stick after the
## controls pass through inverted to take the shortest path through the second
## half of a flip. The two combine as an ellipse, so a diagonal stick sits
## between them.
@export_range(0.0, 179.0, 0.5) var max_bank_deg: float = 110.0
@export_range(0.0, 179.0, 0.5) var max_pitch_deg: float = 110.0
## Attitude spring stiffness, rad/s^2 per rad of error. Higher = snappier.
@export var attitude_p: float = 9.0
## Attitude damping. Roughly 2*sqrt(attitude_p) is critically damped.
@export var attitude_d: float = 6.0

@export_group("Yaw")
@export var max_yaw_rate: float = 1.4
@export var yaw_p: float = 4.0
## Banking also swings the nose round, so a turn is one input instead of two.
## rad/s of yaw at 90 degrees of bank. 0 disables and leaves yaw to the pedals.
@export var bank_turn_rate: float = 0.0
## Rule 4: rotor torque reaction. rad/s of yaw at full collective, before the
## pilot corrects with pedal. 0 disables.
@export var torque_coupling: float = 0.0

@export_group("Flip commitment")
## How far the cyclic must be reversed against an inverted aircraft's rotation
## before it commits to completing the full flip.
@export_range(0.1, 1.0, 0.01) var flip_reversal_input: float = 0.75
## A deliberate hold prevents a quick correction from triggering a full flip.
@export_range(0.0, 1.0, 0.01) var flip_reversal_hold: float = 0.20

@export_group("Crash")
## Impact speed, m/s, that writes off the airframe. Measured against Jolt: the
## summed contact impulse over mass comes out within ~2% of true touchdown
## speed, so this reads directly as "you die above this many m/s".
@export var crash_impact_speed: float = 6.5

@export_group("Rotors")
@export var main_rotor_rpm: float = 320.0
@export var tail_rotor_rpm: float = 1100.0

@onready var input_source: LocalInputSource = $InputSource
@onready var _main_rotor: Node3D = $Model/MainRotor
@onready var _tail_rotor: Node3D = $Model/TailRotor

## Current pilot intent. Overwritten each tick by whoever has authority.
var control := HeliInput.new()

var is_crashed: bool = false

var _spawn_transform := Transform3D.IDENTITY
var _reset_queued := false
var _rotor_spin := 1.0
var _inertia := Vector3.ONE
## Non-zero while a reversed cyclic command is carrying an inverted aircraft
## through the remainder of a full rotation.
var _flip_completion_axis := Vector3.ZERO
var _flip_reversal_time := 0.0


func _ready() -> void:
	_spawn_transform = global_transform
	_inertia = _compute_inertia()
	# The flight model applies its own gravity, so the engine must not add any.
	gravity_scale = 0.0
	# We model our own drag. REPLACE matters: the default COMBINE mode would add
	# the project's default damping on top and quietly halve the top speed.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	can_sleep = false
	continuous_cd = true
	# Needed for get_contact_count() / get_contact_impulse() to report anything.
	contact_monitor = true
	max_contacts_reported = 4
	input_source.enabled = is_local_authority()
	# Start on the lever where we'd hover, so spawning isn't an instant fall.
	input_source.set_throttle(hover_throttle())
	control.throttle = hover_throttle()


## The one gate that decides who is allowed to generate input for this machine.
func is_local_authority() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return peer_id == multiplayer.get_unique_id()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _reset_queued:
		_reset_queued = false
		is_crashed = false
		state.transform = _spawn_transform
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		return

	# A wreck gets no rotor forces at all, so it just tumbles and falls.
	if is_crashed or _check_impact(state):
		state.apply_central_force(Vector3.DOWN * (gravity * mass))
		return

	if is_local_authority():
		control.copy_from(input_source.poll(state.step))

	var basis := state.transform.basis.orthonormalized()
	_update_flip_completion(basis, state.angular_velocity, control, state.step)
	var flight := compute_flight(
		state.transform,
		state.linear_velocity,
		state.angular_velocity,
		control,
		_flip_completion_axis,
	)
	state.apply_central_force(flight[0])
	state.apply_torque(flight[1])


## Once inverted, reversing cyclic against the current rotation means "finish
## the flip", not "take the short way back". Quaternion orientations do not
## retain whole turns, so remember the rotation axis until we are upright and
## settled again.
func _update_flip_completion(
	basis: Basis,
	angular: Vector3,
	ctl: HeliInput,
	delta: float,
) -> void:
	var uprightness := basis.y.dot(Vector3.UP)
	if _flip_completion_axis.length_squared() > 1e-4:
		_flip_reversal_time = 0.0
		var flip_rate := angular.dot(_flip_completion_axis)
		if uprightness > 0.995 and absf(flip_rate) < 0.2:
			_flip_completion_axis = Vector3.ZERO
		return

	# Require a meaningful amount of inversion, not a momentary crossing of the
	# horizon during an ordinary steep bank.
	if uprightness > -0.15:
		_flip_reversal_time = 0.0
		return

	var cyclic := Vector2(ctl.roll, ctl.pitch)
	if cyclic.length() < flip_reversal_input:
		_flip_reversal_time = 0.0
		return

	var tilt_rate := angular - Vector3.UP * angular.dot(Vector3.UP)
	if tilt_rate.length_squared() < 0.04:
		_flip_reversal_time = 0.0
		return

	var level := Basis.from_euler(Vector3(0.0, _heading_of(basis), 0.0))
	var command_axis := (level * Vector3(cyclic.y, 0.0, -cyclic.x)).normalized()
	var is_deliberate_reversal := command_axis.dot(tilt_rate.normalized()) < -0.7
	if is_deliberate_reversal:
		_flip_reversal_time += delta
	else:
		_flip_reversal_time = 0.0
	if _flip_reversal_time >= flip_reversal_hold:
		_flip_completion_axis = tilt_rate.normalized()
		_flip_reversal_time = 0.0


func _check_impact(state: PhysicsDirectBodyState3D) -> bool:
	# Jolt splits one impact across several contact points and resolves it in a
	# single step, so no individual contact carries the whole blow — sum them.
	# It also reports 0.0 for resting contacts, which is why sitting on the pad
	# doesn't slowly accumulate its way into a crash. Both are Jolt behaviours;
	# Godot Physics reports these differently.
	var impulse := 0.0
	for i in state.get_contact_count():
		impulse += state.get_contact_impulse(i).length()
	# Dividing by mass makes the threshold a speed, which stays meaningful if
	# the airframe gets heavier later.
	if impulse > crash_impact_speed * mass:
		is_crashed = true
		control.clear()
		crashed.emit()
		return true
	return false


## The entire flight model. Takes plain state in, hands plain vectors back, and
## touches nothing belonging to the physics engine — not gravity, not the
## inertia tensor, not the body. That is deliberate: when the netcode moves the
## helicopter out of RigidBody3D and onto a custom integrator we can predict and
## re-simulate, this function comes across unchanged.
##
## Returns [force, torque], both world space.
func compute_flight(
	xform: Transform3D,
	velocity: Vector3,
	angular: Vector3,
	ctl: HeliInput,
	flip_completion_axis := Vector3.ZERO,
) -> Array:
	var basis := xform.basis.orthonormalized()
	var up := basis.y
	var force := Vector3.DOWN * (gravity * mass)

	# --- Rotor thrust (rules 1 and 3) -------------------------------------
	# One force, always along the mast. Tilting the machine is the only way to
	# go anywhere, and it costs vertical lift exactly as cos(tilt) says it must.
	var uprightness := maxf(up.dot(Vector3.UP), min_uprightness)
	var compensation := lerpf(1.0, 1.0 / uprightness, lift_compensation)
	var demand := ctl.throttle * max_thrust_ratio
	var airspeed := Vector2(velocity.x, velocity.z).length()
	var translational := 1.0 + translational_lift * smoothstep(0.0, translational_lift_speed, airspeed)
	force += up * (mass * gravity * demand * compensation * translational)

	# --- Drag (rule 2) ----------------------------------------------------
	# Drag is always anti-parallel to velocity; only its *magnitude* depends on
	# which way we're pointing. Resolving a diagonal drag tensor onto the body
	# axes instead would tilt the force off the velocity vector and fake up
	# several m/s^2 of lift whenever the nose is down, which is not a thing.
	# Alignment uses heading only, so drag doesn't change when we pitch or roll.
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	if flat_velocity.length_squared() > 1e-4:
		var flat_nose := Vector3(-basis.z.x, 0.0, -basis.z.z)
		var alignment := 0.0
		if flat_nose.length_squared() > 1e-4:
			alignment = flat_velocity.normalized().dot(flat_nose.normalized())
		var coefficient := lerpf(drag_side, drag_forward, alignment * alignment)
		force += -flat_velocity * coefficient * mass
	force += Vector3.UP * (-velocity.y * vertical_drag * mass)

	# --- Attitude ---------------------------------------------------------
	# Target = level at our current heading, then tilted the way the stick is
	# pointing. Built as a single axis-angle rotation rather than euler angles
	# because euler order YXZ goes singular at 90 degrees of pitch, and we now
	# deliberately let the stick command more than that.
	var level := Basis.from_euler(Vector3(0.0, _heading_of(basis), 0.0))
	var deflection := Vector2.ZERO
	if flip_completion_axis.length_squared() < 1e-4:
		deflection = Vector2(
			ctl.roll * deg_to_rad(max_bank_deg),
			ctl.pitch * deg_to_rad(max_pitch_deg),
		)
	var target := level
	var tilt := deflection.length()
	if tilt > 1e-4:
		# Rotating about +X pitches the nose up, about -Z banks right, so this
		# axis tips the disc in exactly the direction the stick is pushed.
		var axis := level * Vector3(deflection.y, 0.0, -deflection.x).normalized()
		target = level.rotated(axis, tilt)

	# Usually use the shortest-arc error. While completing a flip, select the
	# quaternion sign whose rotation continues along the latched axis instead;
	# that preserves the missing whole-turn information until we are upright.
	var error := Quaternion(basis).inverse() * Quaternion(target)
	var error_direction := basis * Vector3(error.x, error.y, error.z)
	if flip_completion_axis.length_squared() > 1e-4:
		if error_direction.dot(flip_completion_axis) < 0.0:
			error = Quaternion(-error.x, -error.y, -error.z, -error.w)
	elif error.w < 0.0:
		error = Quaternion(-error.x, -error.y, -error.z, -error.w)
	var error_world := basis * (Vector3(error.x, error.y, error.z) * 2.0)

	# Damp only the tilt part; the pedals own rotation about world up.
	var tilt_rate := angular - Vector3.UP * angular.dot(Vector3.UP)
	var ang_accel := error_world * attitude_p - tilt_rate * attitude_d
	ang_accel -= Vector3.UP * ang_accel.dot(Vector3.UP)

	# --- Yaw (rate controlled, like pedals) -------------------------------
	# basis.x.y is how far the right side has dropped, so it goes negative in a
	# right bank and can feed a right-hand turn. Collective can drag the nose
	# right too. Both couplings default off so yaw belongs to the pedals.
	# Torque reaction tracks thrust *relative to hover*: at a steady hover the
	# tail rotor is already trimmed for it, so it's the change you feel.
	var target_yaw_rate := -ctl.yaw * max_yaw_rate \
		+ basis.x.y * bank_turn_rate \
		- (demand - 1.0) * torque_coupling
	ang_accel += Vector3.UP * (target_yaw_rate - angular.dot(Vector3.UP)) * yaw_p

	return [force, _torque_for(basis, ang_accel)]


## Converts a desired angular acceleration into torque, so the gains above are
## in rad/s^2 and stay meaningful if the mass or collision shape changes.
## Uses our own inertia rather than asking the physics server for its tensor.
func _torque_for(basis: Basis, ang_accel: Vector3) -> Vector3:
	# Inertia is diagonal in the body frame, so rotate in, scale, rotate out.
	var local := basis.inverse() * ang_accel
	return basis * (local * _inertia)


## The level heading underneath the aircraft's tilt, in radians.
##
## Reading heading from the nose's horizontal projection makes it jump by 180
## degrees during a forward/back flip: once the nose passes vertical it points
## toward the other horizon even though the pilot has not yawed. Decomposing
## the orientation into swing (tilt) and twist (heading around world up) keeps
## the reference frame stable through roll, pitch, and diagonal inversions.
func _heading_of(basis: Basis) -> float:
	var orientation := Quaternion(basis)
	var twist_length := sqrt(
		orientation.y * orientation.y + orientation.w * orientation.w
	)
	# Swing/twist has one unavoidable singular point at an exact 180-degree
	# tilt. Physics will almost always step across it; this merely keeps the
	# result finite if a transform lands on it exactly.
	if twist_length < 1e-6:
		return 0.0
	var twist_y := orientation.y / twist_length
	var twist_w := orientation.w / twist_length
	return wrapf(2.0 * atan2(twist_y, twist_w), -PI, PI)


## Inversion-safe heading for camera rigs and other presentation code.
func level_heading() -> float:
	return _heading_of(global_basis.orthonormalized())


## Lever position that exactly holds a hover with the disc level.
func hover_throttle() -> float:
	return 1.0 / max_thrust_ratio


## Principal moments of inertia for a solid box, derived from the collision
## shape so they follow it if the airframe is resized.
func _compute_inertia() -> Vector3:
	var box := $CollisionShape3D.shape as BoxShape3D
	if box == null:
		return Vector3.ONE * mass
	var s := box.size
	return Vector3(
		mass * (s.y * s.y + s.z * s.z) / 12.0,
		mass * (s.x * s.x + s.z * s.z) / 12.0,
		mass * (s.x * s.x + s.y * s.y) / 12.0,
	)


func _process(delta: float) -> void:
	# Visual only. Spins a little faster under climb power, and winds down once
	# the airframe is a wreck.
	# A governed rotor holds near-constant RPM, so this barely moves with the
	# lever — it's just enough to read as power without lying about the rules.
	var target_spin := 0.0 if is_crashed else 0.92 + control.throttle * 0.16
	_rotor_spin = move_toward(_rotor_spin, target_spin, delta * (0.35 if is_crashed else 4.0))
	_main_rotor.rotate_y(TAU * (main_rotor_rpm / 60.0) * _rotor_spin * delta)
	_tail_rotor.rotate_x(TAU * (tail_rotor_rpm / 60.0) * _rotor_spin * delta)


func reset() -> void:
	_reset_queued = true
	_flip_completion_axis = Vector3.ZERO
	_flip_reversal_time = 0.0
	_rotor_spin = 1.0
	input_source.center_stick()
	input_source.set_throttle(hover_throttle())
	control.clear()
	control.throttle = hover_throttle()


func set_spawn_transform(t: Transform3D) -> void:
	_spawn_transform = t
