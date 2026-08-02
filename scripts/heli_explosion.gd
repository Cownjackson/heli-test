class_name HeliExplosion
extends Node3D

## Short emissive flash followed by debris sparks and a slower smoke bloom.

@export var duration: float = 1.6
@export var flash_duration: float = 0.22
@export var maximum_flash_scale: float = 5.0

@onready var _flash: MeshInstance3D = $Flash
@onready var _light: OmniLight3D = $Light

var _age := 0.0


func _ready() -> void:
	add_to_group(&"heli_explosion")
	$Fire.restart()
	$Smoke.restart()


func _process(delta: float) -> void:
	_age += delta
	var flash_t := clampf(_age / flash_duration, 0.0, 1.0)
	_flash.scale = Vector3.ONE * lerpf(0.35, maximum_flash_scale, flash_t)
	_light.light_energy = lerpf(7.0, 0.0, flash_t)
	if _age >= flash_duration:
		_flash.visible = false
	if _age >= duration:
		queue_free()
