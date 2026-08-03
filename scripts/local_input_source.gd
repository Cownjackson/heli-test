class_name LocalInputSource
extends Node

## Turns keyboard + mouse into a HeliInput.
##
## The mouse drives a "virtual cyclic stick": mouse motion moves the stick and
## it stays where you left it (like a real cyclic), rather than snapping back.
## Set stick_return above 0 if you'd rather it spring to centre.
##
## Multiplayer note: this node is only enabled on the machine that owns the
## helicopter. Everything else consumes HeliInput from elsewhere.

@export var enabled: bool = false

@export_group("Mouse cyclic")
@export var mouse_sensitivity: float = 0.0022
@export var invert_mouse_pitch: bool = false
## Units of stick per second that the stick drifts back to centre. 0 = holds.
@export var stick_return: float = 0.0

@export_group("Keyboard cyclic")
## How fast the arrow keys sweep the virtual stick, in stick units per second.
@export var key_stick_rate: float = 1.6

@export_group("Cyclic response")
## Softens the middle of the stick without touching the ends, so the big tilt
## angles still exist but you have to go and get them. 0 = linear, 1 = fully
## cubic. At 0.65, half stick asks for ~26% tilt instead of 50%.
## Applied to the stick's magnitude, not per-axis, so the response stays
## identical in every direction rather than bulging along the diagonals.
@export_range(0.0, 1.0, 0.01) var cyclic_expo: float = 0.75

@export_group("Aim lock")
## Stick units per second the cyclic drifts back to centre *while the aim lock
## is held*. 0 = the stick simply freezes where you left it, which is the
## virtual-cyclic behaviour everywhere else. Raise it if you want holding the
## lock to also level the aircraft, so the camera settles instead of continuing
## whatever turn you were already in.
@export var aim_lock_stick_return: float = 0.0

@export_group("Collective")
## How fast W/S drive the collective lever, in lever units per second.
## ~1.3 s from closed to fully open.
@export var throttle_rate: float = 0.75

var stick := Vector2.ZERO
## Absolute lever position, 0..1. Persists between frames — this is the state
## the pilot is managing, and the whole point of the absolute-throttle model.
var throttle: float = 0.0
## True while the pilot is holding the aim lock. Read by the HUD; the weapon
## cursor deliberately does not read it, because aiming is what stays working.
var aim_locked: bool = false

var _mouse_delta := Vector2.ZERO
var _out := HeliInput.new()


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_delta += event.relative


## Called once per physics tick by the helicopter that owns us.
func poll(delta: float) -> HeliInput:
	if not enabled:
		_out.clear()
		_mouse_delta = Vector2.ZERO
		aim_locked = false
		return _out

	# Aiming and flying share one mouse, which is why steering while you line up
	# a shot is so awkward: every correction to the crosshair is also a cyclic
	# input. Holding the lock hands the mouse to the weapon cursor alone. The
	# cyclic is only deaf to the *mouse* — pedals, collective and the arrow keys
	# all keep working, so you are never actually unable to fly.
	aim_locked = Input.is_action_pressed(&"aim_lock")
	if aim_locked:
		_mouse_delta = Vector2.ZERO

	# Mouse: right = bank right, forward (relative.y < 0) = nose down.
	var pitch_sign := -1.0 if invert_mouse_pitch else 1.0
	stick.x += _mouse_delta.x * mouse_sensitivity
	stick.y += _mouse_delta.y * mouse_sensitivity * pitch_sign
	_mouse_delta = Vector2.ZERO

	# Arrow keys nudge the same virtual stick, so the two never fight.
	var key_x := Input.get_axis(&"cyclic_left", &"cyclic_right")
	var key_y := Input.get_axis(&"cyclic_forward", &"cyclic_back")
	stick.x += key_x * key_stick_rate * delta
	stick.y += key_y * key_stick_rate * delta

	var return_rate := aim_lock_stick_return if aim_locked else stick_return
	if return_rate > 0.0:
		stick = stick.move_toward(Vector2.ZERO, return_rate * delta)
	stick = stick.limit_length(1.0)

	var lever := Input.get_axis(&"collective_down", &"collective_up")
	throttle = clampf(throttle + lever * throttle_rate * delta, 0.0, 1.0)

	var command := shaped_stick()
	_out.roll = command.x
	_out.pitch = command.y
	_out.yaw = Input.get_axis(&"yaw_left", &"yaw_right")
	_out.throttle = throttle
	return _out


## Where the stick is actually asking the aircraft to go, after expo. Direction
## is preserved exactly; only the magnitude is curved.
func shaped_stick() -> Vector2:
	var magnitude := stick.length()
	if magnitude < 1e-5:
		return Vector2.ZERO
	return stick / magnitude * lerpf(magnitude, magnitude * magnitude * magnitude, cyclic_expo)


func center_stick() -> void:
	stick = Vector2.ZERO
	_mouse_delta = Vector2.ZERO


func set_throttle(value: float) -> void:
	throttle = clampf(value, 0.0, 1.0)
