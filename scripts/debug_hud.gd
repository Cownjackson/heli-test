extends Control

## Throwaway readout for tuning feel: airspeed, altitude, attitude, and where
## the virtual cyclic actually is. Delete once the flight model is settled.

const STICK_BOX := 110.0
const MARGIN := 16.0

var _heli: Helicopter


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	queue_redraw()


## Helicopters are spawned, so there is no path to point at and the local one
## may not exist yet on the first frames. Re-resolve whenever the cached one has
## gone away or stopped being ours.
func _resolve_heli() -> Helicopter:
	if not is_instance_valid(_heli) or not _heli.is_live() or not _heli.is_local_authority():
		_heli = Helicopter.find_local(get_tree())
	return _heli


func _draw() -> void:
	if _resolve_heli() == null:
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
		"session  %s" % NetworkSession.status_text,
		"players  %d" % get_tree().get_nodes_in_group(Helicopter.GROUP).size(),
		"",
		"W/S collective   A/D pedals",
		"mouse or arrows  cyclic",
		"LMB twin guns",
		"R reset   Esc release mouse",
		"F1 host   F2 join   F3 leave",
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
	_draw_weapon_status(font)
	_draw_crosshair()


## Ammo lives apart from the tuning readout so it remains readable at a glance
## during flight. One ammo unit represents one paired-gun volley.
func _draw_weapon_status(font: Font) -> void:
	if not _heli.weapons:
		return
	var weapons = _heli.weapons
	var panel_size := Vector2(230.0, 82.0)
	var panel_position := size - panel_size - Vector2(MARGIN, MARGIN)
	draw_rect(Rect2(panel_position, panel_size), Color(0.02, 0.035, 0.03, 0.72), true)
	draw_rect(Rect2(panel_position, panel_size), Color(0.55, 0.75, 0.58, 0.55), false, 1.0)

	var ammo_text := "AMMO  %d / %d" % [weapons.ammo, weapons.max_ammo]
	draw_string(font, panel_position + Vector2(12.0, 31.0), ammo_text,
		HORIZONTAL_ALIGNMENT_LEFT, panel_size.x - 24.0, 24, Color(0.95, 0.86, 0.3))

	var status := "READY"
	if weapons.cooldown_remaining > 0.0:
		status = "FIRE IN  %.1f s" % weapons.cooldown_remaining
	elif weapons.ammo <= 0:
		status = "RELOADING"
	if weapons.ammo < weapons.max_ammo:
		var next_round := maxf(0.0, weapons.reload_seconds_per_round - weapons.reload_progress)
		status += "     +1 IN %.1f s" % next_round
	draw_string(font, panel_position + Vector2(12.0, 60.0), status,
		HORIZONTAL_ALIGNMENT_LEFT, panel_size.x - 24.0, 14, Color(0.72, 0.9, 0.76))


func _draw_crosshair() -> void:
	var center: Vector2 = _heli.weapons.aim_position
	var color := Color(0.95, 0.86, 0.3, 0.8)
	draw_arc(center, 8.0, 0.0, TAU, 24, color, 1.5)
	draw_line(center + Vector2(-15.0, 0.0), center + Vector2(-6.0, 0.0), color, 1.5)
	draw_line(center + Vector2(6.0, 0.0), center + Vector2(15.0, 0.0), color, 1.5)
	draw_line(center + Vector2(0.0, -15.0), center + Vector2(0.0, -6.0), color, 1.5)
	draw_line(center + Vector2(0.0, 6.0), center + Vector2(0.0, 15.0), color, 1.5)


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
