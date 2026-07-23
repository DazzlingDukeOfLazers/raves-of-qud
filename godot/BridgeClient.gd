extends Node
class_name BridgeClient

## localhost TCP client for the Caves of Qud bridge mod.
## Emits `snapshot(data: Dictionary)` for each complete frame received.
## Frame format matches mod/Protocol.cs: [4-byte big-endian length][UTF-8 JSON].

signal snapshot(data: Dictionary)

const HOST := "127.0.0.1"
const PORT := 48710  # keep in sync with mod/Protocol.cs DefaultPort

var _peer := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _connected := false
var _retry_accum := 0.0

func _ready() -> void:
	_start_connect()

func _start_connect() -> void:
	var err := _peer.connect_to_host(HOST, PORT)
	if err != OK:
		push_warning("Raves bridge: connect_to_host failed (%s)" % err)

func _process(dt: float) -> void:
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _connected:
				_connected = true
				print("Raves bridge: connected")
			_drain()
		StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
			if _connected:
				_connected = false
				print("Raves bridge: disconnected")
			# retry ~once per second while Qud isn't up yet
			_retry_accum += dt
			if _retry_accum >= 1.0:
				_retry_accum = 0.0
				_peer = StreamPeerTCP.new()
				_buf.clear()
				_start_connect()
		_:
			pass  # STATUS_CONNECTING — wait

func _drain() -> void:
	var avail := _peer.get_available_bytes()
	if avail > 0:
		var res := _peer.get_data(avail)  # -> [err, PackedByteArray]
		if res[0] == OK:
			_buf.append_array(res[1])

	# pull every complete frame out of the buffer
	while _buf.size() >= 4:
		var frame_len := (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3]
		if _buf.size() < 4 + frame_len:
			break
		var payload := _buf.slice(4, 4 + frame_len)
		_buf = _buf.slice(4 + frame_len)
		var text := payload.get_string_from_utf8()
		var data: Variant = JSON.parse_string(text)
		if typeof(data) == TYPE_DICTIONARY:
			snapshot.emit(data)

## Send a command to Qud, e.g. send_command("move", {"dir": "N"}).
func send_command(name: String, extra: Dictionary = {}) -> void:
	if not _connected:
		return
	var msg := {"type": "command", "name": name}
	for k in extra:
		msg[k] = extra[k]
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	_peer.put_data(frame)
