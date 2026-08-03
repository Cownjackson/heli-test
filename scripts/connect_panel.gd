extends Control

## In-game session UI: type an address, host or join, see what happened.
##
## This exists because the join address was previously an exported property,
## which meant it could only be set from the editor — an exported build had no
## way to reach anything. It is also the step most likely to be got wrong, so
## the panel deliberately shows *this machine's* addresses too: the host reads
## its own IP off the screen instead of running ipconfig and guessing which
## adapter is the real one.
##
## Built in code rather than authored as a scene purely so the whole thing stays
## in one readable file. It is developer UI and should be replaced along with the
## debug HUD once the game grows a real menu.

const SETTINGS_PATH := "user://session.cfg"

var _address: LineEdit
var _status: Label
var _locals: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Swallows clicks while open so they don't fall through and re-capture the
	# mouse for flight.
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	NetworkSession.session_started.connect(_on_session_changed.unbind(1))
	NetworkSession.session_ended.connect(_on_session_changed)
	NetworkSession.session_failed.connect(_on_session_changed.unbind(1))
	hide()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(460.0, 0.0)
	margin.add_child(box)

	var title := Label.new()
	title.text = "Multiplayer session"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	box.add_child(HSeparator.new())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	var label := Label.new()
	label.text = "Host address"
	row.add_child(label)

	_address = LineEdit.new()
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.placeholder_text = "192.168.x.x"
	_address.text = _load_address()
	# Enter joins, so the common case is type-and-go.
	_address.text_submitted.connect(func(_t: String) -> void: _join())
	row.add_child(_address)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	_add_button(buttons, "Host", _host)
	_add_button(buttons, "Join", _join)
	_add_button(buttons, "Leave", func() -> void: NetworkSession.leave())
	_add_button(buttons, "Close", func() -> void: set_open(false))

	box.add_child(HSeparator.new())

	_locals = Label.new()
	_locals.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_locals.add_theme_color_override("font_color", Color(0.7, 0.85, 0.75))
	box.add_child(_locals)

	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.65, 0.7, 0.68))
	hint.text = "The host presses Host, then reads its address above to the "  \
		+ "other player, who types it in and presses Join. The host's firewall "  \
		+ "must allow inbound UDP on port %d — Windows asks once and " % NetworkSession.DEFAULT_PORT \
		+ "silently blocks it if that prompt is dismissed."
	box.add_child(hint)


func _add_button(parent: Node, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)


func set_open(open: bool) -> void:
	visible = open
	if open:
		_refresh()
		_address.grab_focus()
		_address.select_all()
	get_tree().call_group(&"session_ui_listeners", &"on_session_ui_toggled", open)


func toggle() -> void:
	set_open(not visible)


func _host() -> void:
	NetworkSession.host()
	_refresh()


func _join() -> void:
	var address := _address.text.strip_edges()
	if address.is_empty():
		_status.text = "Enter the host's address first."
		return
	_save_address(address)
	NetworkSession.join(address)
	_refresh()


func _on_session_changed() -> void:
	if visible:
		_refresh()


func _refresh() -> void:
	_status.text = NetworkSession.status_text
	var lines := PackedStringArray(["This machine:"])
	for address in local_addresses():
		lines.append("    %s   %s" % [address, describe_address(address)])
	_locals.text = "\n".join(lines)


## IPv4 addresses this machine answers on, loopback excluded.
##
## Deliberately unfiltered beyond that: a machine can legitimately have several,
## and silently picking one is worse than showing them all with a note about
## what each is likely to be.
static func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.begins_with("127.") or not address.is_valid_ip_address():
			continue
		if ":" in address:
			continue
		out.append(address)
	return out


## Best guess at what an address is for, so the host can read the right one out
## instead of trying all three. Heuristics, not certainties — a machine really
## can have its LAN on 172.x — so these are worded as likelihoods.
static func describe_address(address: String) -> String:
	if address.begins_with("169.254."):
		return "<- link-local, not usable"
	if address.begins_with("172."):
		# 172.16-31 is private, but on Windows it is nearly always WSL or Docker.
		return "<- probably a virtual adapter (WSL/Docker)"
	if address.begins_with("192.168.") or address.begins_with("10."):
		return "<- this is probably the one"
	return ""


func _load_address() -> String:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return ""
	return str(config.get_value("session", "address", ""))


func _save_address(address: String) -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("session", "address", address)
	config.save(SETTINGS_PATH)
