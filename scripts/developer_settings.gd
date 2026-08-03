class_name DeveloperSettings
extends PanelContainer

## Runtime tuning panel for combat feel. Rows are generated from ROWS rather
## than authored in the scene, because the whole point is that adding a knob
## should cost one line.
##
## Every value is written to **SceneTree metadata as well as to live nodes**.
## Helicopters and projectiles are spawned continuously, so a slider that only
## touched what already existed would be undone by the next respawn or the next
## volley. `tuned()` is the read side of that, called from `_ready()`.
##
## **Networking: these sliders only bite on the host.** Damage, blast and health
## are evaluated exclusively on the server, so dragging them on a client changes
## nothing anyone can see. Tune on the machine that pressed Host.

const ROWS: Array[Dictionary] = [
	{
		"key": &"projectile_time_scale", "label": "Projectile time",
		"min": 0.25, "max": 2.0, "step": 0.05, "value": 1.0, "format": "%.2f x",
	},
	{
		"key": &"damage", "label": "Missile damage",
		"min": 0.0, "max": 60.0, "step": 1.0, "value": 20.0, "format": "%.0f",
	},
	{
		"key": &"max_health", "label": "Airframe health",
		"min": 20.0, "max": 400.0, "step": 5.0, "value": 100.0, "format": "%.0f",
	},
	{
		"key": &"blast_impulse", "label": "Blast impulse",
		"min": 0.0, "max": 24000.0, "step": 200.0, "value": 7200.0, "format": "%.0f N·s",
	},
	{
		"key": &"blast_lift", "label": "Blast lift",
		"min": 0.0, "max": 2.0, "step": 0.05, "value": 0.45, "format": "%.2f",
	},
	{
		"key": &"blast_spin", "label": "Blast spin",
		"min": 0.0, "max": 1.0, "step": 0.01, "value": 0.35, "format": "%.2f",
	},
	{
		"key": &"double_hit_bonus", "label": "Double-hit bonus",
		"min": 1.0, "max": 3.0, "step": 0.05, "value": 1.5, "format": "%.2f x",
	},
]

var _value_labels := {}


## The read side. Anything spawned at runtime asks for its tuned value here and
## falls back to whatever the scene gave it, so the panel is optional.
static func tuned(tree: SceneTree, key: StringName, fallback: float) -> float:
	if tree != null and tree.has_meta(key):
		return float(tree.get_meta(key))
	return fallback


func _ready() -> void:
	_build_rows()
	# Sized from its contents rather than fixed offsets, so adding a row to ROWS
	# doesn't silently clip the panel.
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)


func _build_rows() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 12)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.custom_minimum_size.x = 260.0
	margin.add_child(column)

	var title := Label.new()
	title.text = "DEVELOPER — COMBAT TUNING"
	column.add_child(title)

	for row in ROWS:
		_build_row(column, row)

	var hint := Label.new()
	hint.text = "Esc: release mouse   F5: hide   (host only)"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)


func _build_row(column: VBoxContainer, row: Dictionary) -> void:
	var key: StringName = row["key"]

	var header := HBoxContainer.new()
	column.add_child(header)

	var name_label := Label.new()
	name_label.text = row["label"]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(value_label)
	_value_labels[key] = value_label

	var slider := HSlider.new()
	slider.min_value = row["min"]
	slider.max_value = row["max"]
	slider.step = row["step"]
	slider.value = row["value"]
	slider.value_changed.connect(_on_row_changed.bind(row))
	column.add_child(slider)

	_on_row_changed(row["value"], row)


func _on_row_changed(value: float, row: Dictionary) -> void:
	var key: StringName = row["key"]
	(_value_labels[key] as Label).text = row["format"] % value
	get_tree().set_meta(key, value)
	_apply_live(key, value)


## Pushes a value onto everything already in the world. New nodes get it from
## the metadata instead; both paths have to exist or tuning is either invisible
## until the next respawn, or forgotten at it.
func _apply_live(key: StringName, value: float) -> void:
	match key:
		&"projectile_time_scale":
			for weapons in get_tree().get_nodes_in_group(&"heli_weapons"):
				weapons.set_projectile_time_scale(value)
			for projectile in get_tree().get_nodes_in_group(&"heli_projectile"):
				projectile.fallback_time_scale = value
			for explosion in get_tree().get_nodes_in_group(&"heli_explosion"):
				explosion.time_scale = value
		&"damage", &"blast_impulse", &"blast_lift", &"blast_spin":
			for projectile in get_tree().get_nodes_in_group(&"heli_projectile"):
				projectile.set(key, value)
		&"max_health":
			# Refill on change. Half a health bar measured against a pool that
			# has since moved tells you nothing, and mid-test the honest reading
			# is always "how many hits from full".
			for node in get_tree().get_nodes_in_group(Helicopter.GROUP):
				var heli := node as Helicopter
				if heli != null:
					heli.max_health = value
					heli.health = value
		&"double_hit_bonus":
			for node in get_tree().get_nodes_in_group(Helicopter.GROUP):
				var heli := node as Helicopter
				if heli != null:
					heli.double_hit_bonus = value
