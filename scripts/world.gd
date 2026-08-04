extends Node3D

## Test level. Scatters blocks purely so there's something to judge speed and
## altitude against — untextured ground gives you no motion cues at all.
##
## Multiplayer note: everything spawned here is static scenery, generated from
## a fixed seed so every peer builds an identical world without syncing it.
##
## Helicopters are *spawned*, not placed in the scene. Nothing may hold a fixed
## path to one — there is no longer a node called "Helicopter", and which
## aircraft belongs to this machine is only known at runtime. Use
## `Helicopter.find_local()`.

## Peer id that owns the aircraft when there is no network. Matches what
## `multiplayer.get_unique_id()` reports offline, so one rule covers both cases.
const OFFLINE_PEER := 1

const SPAWN_HEIGHT := 25.0
const SPAWN_RING := 35.0

@export var obstacle_count: int = 90
@export var field_radius: float = 420.0
@export var world_seed: int = 20260801

@export_group("Players")
@export var helicopter_scene: PackedScene
## Spawns a second, unowned helicopter as a stationary target. Purely a
## development aid for weapons work; it is not a player and never accepts input.
@export var spawn_test_target: bool = true

@export_group("Session")
## Address F2 connects to. Set this to the host's LAN IP to test across two
## machines; the default only reaches another instance on this one.
@export var join_address: String = "127.0.0.1"

@onready var _players: Node3D = $Players
@onready var _projectiles: Node3D = $Projectiles
@onready var _spawner: MultiplayerSpawner = $HelicopterSpawner
@onready var _connect_panel: Control = $HUD/ConnectPanel
@onready var _developer_settings: Control = $HUD/DeveloperSettings

## Cached only as an optimisation. Always go through _local_heli(), which
## re-resolves if the aircraft was despawned or ownership changed.
var _heli: Helicopter
## Server-side only. Spawn slots are handed out in join order and travel in the
## spawn payload, so every peer places every aircraft identically.
var _next_spawn_index := 0


func _ready() -> void:
	# The connect panel tells us when it opens so we can release the mouse.
	add_to_group(&"session_ui_listeners")
	_build_obstacles()
	# The spawner runs this on *every* peer to reconstruct the aircraft locally;
	# only the server ever calls spawn().
	_spawner.spawn_function = _build_helicopter

	NetworkSession.session_started.connect(_on_session_started)
	NetworkSession.session_ended.connect(_on_session_ended)
	NetworkSession.session_failed.connect(_on_session_failed)
	NetworkSession.peer_joined.connect(_on_peer_joined)
	NetworkSession.peer_left.connect(_on_peer_left)

	NetworkSession.apply_command_line()
	if not NetworkSession.is_active():
		_populate_offline()
	_capture_mouse()


## Builds one aircraft, without parenting it.
##
## This is the `MultiplayerSpawner` spawn function, so it must be a pure
## construction step: the spawner does the adding, and doing it here too would
## reparent the node. It also must produce an identical result from identical
## data on every peer, which is why placement comes from the payload rather than
## from local child counts.
##
## Ownership is assigned here, before the node enters the tree, because
## `Helicopter._ready()` reads `peer_id` to enable its input source and pick
## which camera becomes current — neither is cleanly reversible afterwards.
func _build_helicopter(data: Dictionary) -> Helicopter:
	var for_peer := int(data.get("peer", OFFLINE_PEER))
	# Guarded here as well as in spawn_helicopter(): on a client this runs from
	# the spawner, where nobody has checked anything, and a null scene would
	# otherwise fail as a bare crash inside engine code.
	if helicopter_scene == null:
		push_error("world.gd: helicopter_scene is not set, cannot build peer %d." % for_peer)
		return null
	print("world: building helicopter for peer %d (index %d)" % [
		for_peer, int(data.get("index", 0))])
	var heli := helicopter_scene.instantiate() as Helicopter
	heli.name = "Helicopter%d" % for_peer
	heli.peer_id = for_peer
	# Offline there is no get_unique_id() to compare against, so mirror the same
	# rule by hand rather than letting the flag default every aircraft to local.
	heli.offline_local_control = for_peer == OFFLINE_PEER
	heli.transform = spawn_transform_for(int(data.get("index", 0)))
	return heli


## Server-side spawn. Offline this parents directly, because the spawner has no
## peers to replicate to and refuses to run without one.
func spawn_helicopter(for_peer: int) -> void:
	if helicopter_scene == null:
		push_error("world.gd: helicopter_scene is not set, cannot spawn players.")
		return
	var data := {"peer": for_peer, "index": _next_spawn_index}
	_next_spawn_index += 1
	if NetworkSession.is_active():
		_spawner.spawn(data)
	else:
		_players.add_child(_build_helicopter(data))


func despawn_helicopter(for_peer: int) -> void:
	var heli := _players.get_node_or_null("Helicopter%d" % for_peer)
	if heli:
		# Freeing on the server is what tells the spawner to remove the replica.
		heli.queue_free()


func _populate_offline() -> void:
	_next_spawn_index = 0
	spawn_helicopter(OFFLINE_PEER)
	if spawn_test_target:
		spawn_helicopter(OFFLINE_PEER + 1)


func _clear_players() -> void:
	for child in _players.get_children():
		_players.remove_child(child)
		child.queue_free()
	_heli = null
	_next_spawn_index = 0


func _clear_projectiles() -> void:
	for child in _projectiles.get_children():
		_projectiles.remove_child(child)
		child.queue_free()


func _on_session_started(as_server: bool) -> void:
	# Whatever was flying belonged to the previous (offline) session.
	_clear_players()
	_clear_projectiles()
	if as_server:
		spawn_helicopter(multiplayer.get_unique_id())
	# A client spawns nothing: every aircraft, including its own, arrives from
	# the server through the spawner.


func _on_session_ended() -> void:
	_clear_players()
	_clear_projectiles()
	_populate_offline()


## A failed connection must not leave the player stranded with no aircraft. The
## offline session is the fallback, and it is always safe to return to.
func _on_session_failed(_reason: String) -> void:
	if get_tree().get_nodes_in_group(Helicopter.GROUP).is_empty():
		_populate_offline()


func _on_peer_joined(id: int) -> void:
	if NetworkSession.is_server:
		spawn_helicopter(id)


func _on_peer_left(id: int) -> void:
	if NetworkSession.is_server:
		despawn_helicopter(id)


## Deterministic spawn placement: index 0 gets the pad, everyone else is spread
## around it facing in. Computed from the index rather than stored in the scene
## so every peer agrees without syncing spawn points.
func spawn_transform_for(index: int) -> Transform3D:
	var origin := Vector3(0.0, SPAWN_HEIGHT, 0.0)
	if index <= 0:
		return Transform3D(Basis.IDENTITY, origin)
	var angle := TAU * float(index - 1) / 6.0
	# Yaw equal to the ring angle points the nose back at the pad.
	return Transform3D(
		Basis.from_euler(Vector3(0.0, angle, 0.0)),
		origin + Vector3(sin(angle), 0.0, cos(angle)) * SPAWN_RING,
	)


func _local_heli() -> Helicopter:
	if not is_instance_valid(_heli) or not _heli.is_live() or not _heli.is_local_authority():
		_heli = Helicopter.find_local(get_tree())
	return _heli


## Session controls are raw keycodes rather than input-map actions purely to
## avoid churn in project.godot while the weapons branch is open. They are a
## development shortcut and belong in a real menu eventually.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_F1:
			NetworkSession.host()
		KEY_F2:
			NetworkSession.join(join_address)
		KEY_F3:
			NetworkSession.leave()
		KEY_F4:
			_connect_panel.toggle()
		KEY_F5:
			# The combat sliders are large and only useful while tuning.
			_developer_settings.visible = not _developer_settings.visible
		KEY_F6:
			# Prototype A/B (open question 10). A keybind rather than a slider
			# because the only useful way to judge it is to flip it mid-flight
			# and fly the same manoeuvre twice.
			_toggle_edge_yaw()
		_:
			return
	get_viewport().set_input_as_handled()


## Flips the edge-yaw camera prototype on the aircraft this machine is flying.
## Deliberately local and unreplicated: it changes nothing but this player's own
## camera, so the other pilot is unaffected and both can evaluate independently.
func _toggle_edge_yaw() -> void:
	var heli := _local_heli()
	if heli == null:
		return
	var rig := heli.get_node_or_null(^"CameraRig")
	if rig == null:
		return
	rig.edge_yaw_enabled = not rig.edge_yaw_enabled
	print("edge-yaw camera: ", "ON" if rig.edge_yaw_enabled else "OFF")


## Called by the connect panel. Flying needs the mouse captured; typing an
## address needs it back.
func on_session_ui_toggled(open: bool) -> void:
	if open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"reset_heli"):
		var heli := _local_heli()
		if heli:
			heli.reset()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_mouse"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			_capture_mouse()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		# Clicking the world re-captures, but not while the panel wants the
		# cursor for typing.
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _connect_panel.visible:
			_capture_mouse()


func _capture_mouse() -> void:
	if _connect_panel.visible:
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var heli := _local_heli()
	if heli == null:
		return
	heli.input_source.center_stick()
	heli.weapons.center_aim()


func _build_obstacles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.44, 0.47)
	material.roughness = 0.9

	var parent := Node3D.new()
	parent.name = "Obstacles"
	add_child(parent)

	for i in obstacle_count:
		# Bias away from the spawn pad so you're not boxed in at startup.
		var angle := rng.randf() * TAU
		var distance := lerpf(45.0, field_radius, sqrt(rng.randf()))
		var height := rng.randf_range(12.0, 95.0)
		var width := rng.randf_range(8.0, 22.0)
		var depth := rng.randf_range(8.0, 22.0)
		var size := Vector3(width, height, depth)

		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		mesh.material_override = material

		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape

		var body := StaticBody3D.new()
		body.position = Vector3(cos(angle) * distance, height * 0.5, sin(angle) * distance)
		body.rotation.y = rng.randf() * TAU
		body.add_child(mesh)
		body.add_child(shape)
		parent.add_child(body)
