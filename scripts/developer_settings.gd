extends PanelContainer

## Runtime tuning panel. The value is stored on SceneTree so helicopters added
## later by a MultiplayerSpawner inherit the same local developer setting.

@onready var _value_label: Label = $Margin/VBox/Value
@onready var _slider: HSlider = $Margin/VBox/Slider


func _ready() -> void:
	_slider.value_changed.connect(_apply_projectile_time_scale)
	_apply_projectile_time_scale(_slider.value)


func _apply_projectile_time_scale(value: float) -> void:
	var scale := clampf(value, 0.1, 3.0)
	_value_label.text = "%.2f x" % scale
	get_tree().set_meta(&"projectile_time_scale", scale)
	for weapons in get_tree().get_nodes_in_group(&"heli_weapons"):
		weapons.set_projectile_time_scale(scale)
	for projectile in get_tree().get_nodes_in_group(&"heli_projectile"):
		projectile.fallback_time_scale = scale
	for explosion in get_tree().get_nodes_in_group(&"heli_explosion"):
		explosion.time_scale = scale
