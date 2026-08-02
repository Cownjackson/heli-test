extends Control

## Throwaway readout for tuning feel: airspeed, altitude, attitude, and where
## the virtual cyclic actually is. Delete once the flight model is settled.

@export var heli_path: NodePath

const STICK_BOX := 110.0
const MARGIN := 16.0

var _heli: Helicopter


func _ready() -> void:
	_heli = get_node_or_null(heli_path) as Helicopter
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if not _heli:
		return

	var font := ThemeDB.fallback_font
	var font_size := 15
	var color := Color(0.85, 0.95, 0.85)
	var velocity := _heli.linear_velocity
	var horizontal := Vector2(velocity.x, velocity.z).length()
	var euler := _heli.global_basis.get_euler(EULER_ORDER_YXZ)

	var tilt := rad_to_deg(acos(clampf(_heli.global_basis.y.dot(Vector3.UP), -1.0, 1.0)))
	var lines := [
		"speed    %5.1f m/s  (%4.1f up)" % [horizontal, velocity.y],
		"alt      %5.1f m" % _heli.global_position.y,
		"bank     %5.1f deg" % rad_to_deg(-euler.z),
		"pitch    %5.1f deg" % rad_to_deg(euler.x),
		"tilt     %5.1f deg" % tilt,
		"throttle %4.0f %%   (hover %.0f %%)" % [_heli.control.throttle * 100.0, _heli.hover_throttle() * 100.0],
		"",
		"W/S collective   A/D pedals",
		"mouse or arrows  cyclic",
		"R reset   Esc release mouse",
	]
	var y := MARGIN + font_size
	for line: String in lines:
		draw_string(font, Vector2(MARGIN, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		y += font_size + 4

	if _heli.is_crashed:
		var banner_width := size.x - MARGIN * 2.0
		draw_string(font, Vector2(MARGIN, size.y * 0.4), "WRECKED - press R",
			HORIZONTAL_ALIGNMENT_CENTER, banner_width, 40, Color(0.95, 0.35, 0.25))

	var stick_center := Vector2(MARGIN + STICK_BOX * 0.5, y + STICK_BOX * 0.5 + 8.0)
	_draw_stick(stick_center)
	_draw_lever(Vector2(stick_center.x + STICK_BOX * 0.5 + 26.0, stick_center.y))


## Collective lever with a tick at the hover setting. With an absolute lever
## you're managing a position, so it has to be visible to be flyable.
func _draw_lever(center: Vector2) -> void:
	var half := STICK_BOX * 0.5
	var width := 14.0
	var frame := Color(0.6, 0.75, 0.6, 0.5)
	draw_rect(Rect2(center - Vector2(width * 0.5, half), Vector2(width, STICK_BOX)), frame, false, 1.0)

	var fill := STICK_BOX * _heli.control.throttle
	draw_rect(Rect2(Vector2(center.x - width * 0.5, center.y + half - fill), Vector2(width, fill)),
		Color(0.4, 0.8, 0.5, 0.55))

	var hover_y := center.y + half - STICK_BOX * _heli.hover_throttle()
	draw_line(Vector2(center.x - width * 0.5 - 4.0, hover_y), Vector2(center.x + width * 0.5 + 4.0, hover_y),
		Color(0.95, 0.85, 0.3), 1.5)


## Little box showing the virtual cyclic, so drift is obvious while flying.
func _draw_stick(center: Vector2) -> void:
	var half := STICK_BOX * 0.5
	var frame := Color(0.6, 0.75, 0.6, 0.5)
	draw_rect(Rect2(center - Vector2(half, half), Vector2(STICK_BOX, STICK_BOX)), frame, false, 1.0)
	draw_line(center - Vector2(half, 0.0), center + Vector2(half, 0.0), frame * Color(1, 1, 1, 0.5), 1.0)
	draw_line(center - Vector2(0.0, half), center + Vector2(0.0, half), frame * Color(1, 1, 1, 0.5), 1.0)

	# Drawn in mouse space: top of the box is stick forward, i.e. nose down.
	# Hollow ring is where the stick physically is, solid dot is what the
	# aircraft is being asked for after expo — the gap between them is the curve.
	var stick: Vector2 = _heli.input_source.stick
	var commanded: Vector2 = _heli.input_source.shaped_stick()
	draw_arc(center + stick * half, 5.0, 0.0, TAU, 16, Color(0.9, 0.9, 0.4, 0.45), 1.0)
	var dot := center + commanded * half
	draw_line(center, dot, Color(0.9, 0.9, 0.4, 0.7), 1.5)
	draw_circle(dot, 5.0, Color(0.95, 0.85, 0.3))
