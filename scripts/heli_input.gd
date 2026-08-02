class_name HeliInput
extends RefCounted

## One frame of pilot intent, decoupled from where it came from.
##
## Nothing in here touches Input directly. A local player fills it from the
## keyboard/mouse, and later a remote player will fill it from the network.
## Keeping the flight model a pure function of (body state, HeliInput, delta)
## is what makes prediction/reconciliation possible without a rewrite.

## -1 = nose down, +1 = nose up.
var pitch: float = 0.0
## -1 = bank left, +1 = bank right.
var roll: float = 0.0
## -1 = yaw left, +1 = yaw right.
var yaw: float = 0.0
## Collective lever *position*, 0 = closed, 1 = full power. Absolute, not a
## rate: a real collective is a lever you park, and sending the position rather
## than up/down deltas also means a dropped packet can't leave a client and the
## server permanently disagreeing about how much power is in.
var throttle: float = 0.0


func clear() -> void:
	pitch = 0.0
	roll = 0.0
	yaw = 0.0
	throttle = 0.0


func copy_from(other: HeliInput) -> void:
	pitch = other.pitch
	roll = other.roll
	yaw = other.yaw
	throttle = other.throttle


## Compact wire format. Cheap enough to send every physics tick.
func to_array() -> PackedFloat32Array:
	return PackedFloat32Array([pitch, roll, yaw, throttle])


func from_array(a: PackedFloat32Array) -> void:
	if a.size() != 4:
		return
	pitch = a[0]
	roll = a[1]
	yaw = a[2]
	throttle = a[3]
