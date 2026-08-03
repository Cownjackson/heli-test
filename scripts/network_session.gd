extends Node

## Owns the ENet peer and the lifecycle of a LAN session. Autoloaded as
## `NetworkSession`.
##
## Deliberately thin. It answers exactly one question — who is connected — and
## has no opinion about helicopters. The world listens to its signals and does
## the spawning, which keeps the transport testable on its own and means
## gameplay code never touches `multiplayer.multiplayer_peer` directly.
##
## Scope is LAN. There is no matchmaking, no NAT traversal and no relay,
## because the first playable build is two machines on one switch. See
## docs/architecture.md on why that also lets us defer prediction entirely.

signal session_started(as_server: bool)
signal session_ended()
## A remote peer joined or left. Never emitted for ourselves.
signal peer_joined(id: int)
signal peer_left(id: int)
## Carries a human-readable reason; the HUD shows it.
signal session_failed(reason: String)

const DEFAULT_PORT := 27015
const MAX_PLAYERS := 8

## True while a real ENet peer is up and we are the authority.
var is_server: bool = false
## Set while connecting, cleared once the connection resolves either way.
var is_connecting: bool = false
var status_text: String = "offline"


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## True only when a *real* peer is connected. Mirrors `Helicopter.is_networked()`
## and exists for the same reason: `multiplayer.has_multiplayer_peer()` is true
## offline, because Godot installs an `OfflineMultiplayerPeer` by default.
func is_active() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer)


func host(port: int = DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		# Almost always "port already in use" — i.e. a second instance on the
		# same machine, which is exactly how this gets tested.
		_fail("could not host on port %d (error %d)" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_connecting = false
	status_text = "hosting on port %d" % port
	session_started.emit(true)
	return OK


func join(address: String, port: int = DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		_fail("could not reach %s:%d (error %d)" % [address, port, err])
		return err
	multiplayer.multiplayer_peer = peer
	is_server = false
	# create_client() returning OK only means the socket was created. Whether
	# anyone is listening is not known until connected_to_server or
	# connection_failed arrives, which is why this is a separate state.
	is_connecting = true
	status_text = "connecting to %s:%d" % [address, port]
	return OK


func leave() -> void:
	if not is_active():
		return
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	is_connecting = false
	status_text = "offline"
	session_ended.emit()


## Reads `--host` / `--join=<address>` from the arguments after a bare `--`.
##
## Called by the world rather than from `_ready()` on purpose: autoloads are
## ready before the main scene, so hosting here would emit session_started
## before anything had connected to it.
func apply_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			host()
			return
		if arg.begins_with("--join"):
			var address := "127.0.0.1"
			var split := arg.split("=", false, 1)
			if split.size() > 1 and not split[1].is_empty():
				address = split[1]
			join(address)
			return


func _fail(reason: String) -> void:
	is_server = false
	is_connecting = false
	status_text = reason
	push_warning("NetworkSession: %s" % reason)
	session_failed.emit(reason)


func _on_peer_connected(id: int) -> void:
	peer_joined.emit(id)


func _on_peer_disconnected(id: int) -> void:
	peer_left.emit(id)


func _on_connected_to_server() -> void:
	is_connecting = false
	status_text = "connected as peer %d" % multiplayer.get_unique_id()
	# Emitted here rather than in join(), so it always means "the session is
	# genuinely up" for both the server and client paths.
	session_started.emit(false)


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	_fail("connection refused — is the host running?")


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	is_server = false
	is_connecting = false
	status_text = "host closed the session"
	session_ended.emit()
