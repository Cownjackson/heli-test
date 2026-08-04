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
	var font := ThemeDB.fallback_font
	if _resolve_heli() == null:
		# Never go blank. A HUD that vanishes tells the player nothing; if there
		# is no aircraft to fly, the session state is exactly what they need.
		_draw_no_aircraft(font)
		return

	var font_size := 15
	var color := Color(0.85, 0.95, 0.85)
	# Not linear_velocity: a replicated aircraft is frozen, so on a client that
	# reads zero even for the helicopter you are flying.
	var velocity := _heli.current_velocity()
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
		"health   %5.1f / %.0f" % [_heli.health, _heli.max_health],
		"",
		"session  %s" % NetworkSession.status_text,
		"players  %d" % get_tree().get_nodes_in_group(Helicopter.GROUP).size(),
		"",
	]
	# Everyone else's health, because tuning damage against a target whose health
	# you cannot see is guesswork — and solo, the test target is the only thing
	# there is to shoot.
	var others := _other_helicopters()
	for other in others:
		lines.append("target %-13s %3.0f %% %s" % [
			other.name,
			other.health / maxf(1.0, other.max_health) * 100.0,
			"WRECKED" if other.is_crashed else "",
		])
	if not others.is_empty():
		lines.append("")
	lines.append_array([
		"W/S collective   A/D pedals",
		"mouse or arrows  cyclic",
		"LMB twin guns   Alt/RMB aim lock",
		"R reset   Esc release mouse",
		"F1 host  F2 join  F3 leave  F5 tuning",
		"F6 edge-yaw camera  [%s]" % ("ON" if _edge_yaw_on() else "off"),
	])
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


## Shown whenever this machine has no aircraft it is allowed to fly. That is
## normal for a moment after joining, and a fault if it persists — so say which.
func _draw_no_aircraft(font: Font) -> void:
	var total := get_tree().get_nodes_in_group(Helicopter.GROUP).size()
	var lines := [
		"NO AIRCRAFT",
		"",
		"session  %s" % NetworkSession.status_text,
		"peer id  %s" % (str(multiplayer.get_unique_id()) if NetworkSession.is_active() else "-"),
		"helicopters in world  %d" % total,
	]
	if NetworkSession.is_active() and not NetworkSession.is_server:
		lines.append("")
		if total == 0:
			lines.append("Connected, but the host has sent no aircraft.")
			lines.append("Check both machines run the same commit and")
			lines.append("the same Godot version.")
		else:
			lines.append("Aircraft present but none owned by this peer.")
	lines.append("")
	lines.append("F3 leave and return to single player")

	var y := 120.0
	for line: String in lines:
		draw_string(font, Vector2(MARGIN + 8.0, y), line,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.95, 0.6, 0.4))
		y += 24.0


## Every live helicopter except the one being flown, in a stable order so the
## readout doesn't reshuffle between frames.
## A held mode with no tell is indistinguishable from a bug, and this one is a
## prototype that gets flipped mid-flight on purpose.
func _edge_yaw_on() -> bool:
	if _heli == null:
		return false
	var rig := _heli.get_node_or_null(^"CameraRig")
	return rig != null and rig.edge_yaw_enabled


func _other_helicopters() -> Array[Helicopter]:
	var others: Array[Helicopter] = []
	for node in get_tree().get_nodes_in_group(Helicopter.GROUP):
		var heli := node as Helicopter
		if heli != null and heli != _heli and heli.is_live():
			others.append(heli)
	others.sort_custom(func(a: Helicopter, b: Helicopter) -> bool: return a.name < b.name)
	return others


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

	# Health sits directly above the ammo, because in a fight they are the same
	# glance: how much can I still give, and how much can I still take.
	var bar := Rect2(panel_position - Vector2(0.0, 22.0), Vector2(panel_size.x, 14.0))
	var fraction := clampf(_heli.health / maxf(1.0, _heli.max_health), 0.0, 1.0)
	draw_rect(bar, Color(0.02, 0.035, 0.03, 0.72), true)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * fraction, bar.size.y)),
		Color(0.9, 0.3, 0.25) if fraction < 0.34 else Color(0.4, 0.8, 0.5), true)
	draw_rect(bar, Color(0.55, 0.75, 0.58, 0.55), false, 1.0)
	draw_string(font, bar.position + Vector2(6.0, 11.0), "%.0f" % _heli.health,
		HORIZONTAL_ALIGNMENT_LEFT, bar.size.x - 12.0, 11, Color(0.95, 0.97, 0.95))

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
	# The lock is a held, invisible mode: without a tell you cannot see whether
	# the mouse is currently flying the aircraft or only moving the crosshair.
	var locked: bool = _heli.input_source.aim_locked
	var color := Color(0.45, 0.85, 1.0, 0.95) if locked else Color(0.95, 0.86, 0.3, 0.8)
	draw_arc(center, 8.0, 0.0, TAU, 24, color, 1.5)
	draw_line(center + Vector2(-15.0, 0.0), center + Vector2(-6.0, 0.0), color, 1.5)
	draw_line(center + Vector2(6.0, 0.0), center + Vector2(15.0, 0.0), color, 1.5)
	draw_line(center + Vector2(0.0, -15.0), center + Vector2(0.0, -6.0), color, 1.5)
	draw_line(center + Vector2(0.0, 6.0), center + Vector2(0.0, 15.0), color, 1.5)
	if locked:
		draw_arc(center, 13.0, 0.0, TAU, 32, Color(color, 0.35), 1.0)


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
