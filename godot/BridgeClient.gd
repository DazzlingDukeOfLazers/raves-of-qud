extends Node
class_name BridgeClient

## localhost TCP client for the Caves of Qud bridge mod.
## Emits `snapshot(data: Dictionary)` for each complete frame received.
## Frame format matches mod/Protocol.cs: [4-byte big-endian length][UTF-8 JSON].

signal snapshot(data: Dictionary)
signal popup(data: Dictionary)   # a Qud modal mirrored from the mod ({"type":"popup", active:…})
signal picker(data: Dictionary)  # Qud's PickGameObjectScreen mirrored ({"type":"picker", active:…})
signal connected   # fires each time the bridge (re)connects

const HOST := "127.0.0.1"
const PORT := 48710  # keep in sync with mod/Protocol.cs DefaultPort

## Which Qud to render: the Options "Bridge" host/port (Settings), falling back to the
## localhost defaults. Lets Raves point at Qud on another machine without a rebuild.
static func host() -> String:
	return str(Settings.get_value("bridge_host", HOST))
static func port() -> int:
	return int(Settings.get_value("bridge_port", PORT))

var _peer := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _connected := false
var _retry_accum := 0.0

func _ready() -> void:
	_start_connect()

func _start_connect() -> void:
	var err := _peer.connect_to_host(host(), port())
	if err != OK:
		push_warning("Raves bridge: connect_to_host failed (%s)" % err)

func _process(dt: float) -> void:
	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _connected:
				_connected = true
				print("Raves bridge: connected")
				connected.emit()
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

	# Pull every complete frame out of the buffer, but RENDER ONLY THE LATEST. Snapshots are full
	# state, not deltas, so any earlier one is stale the moment a newer one exists. This is a
	# coalescing command buffer: a single zone rebuild can take 1–3s, during which several
	# snapshots pile up in the socket (a burst of transition turns, or two quick Shift+Space
	# waits). Emitting each of them ran that many heavy full-zone rebuilds back-to-back in one
	# frame, which overflowed Godot's Metal buffer allocator and HARD-CRASHED. One rebuild per
	# frame, always to the newest state — fixes the crash and skips straight to current.
	# Snapshots coalesce to the newest (full state, so older ones are stale). Popup frames ride the SAME
	# socket but MUST NOT be coalesced away by a snapshot — they carry modal state Raves has to act on —
	# so they're bucketed separately and emitted after the snapshot (popup wins if both arrive together).
	var latest: Variant = null
	var latest_popup: Variant = null
	var latest_picker: Variant = null
	var dropped := 0
	while _buf.size() >= 4:
		var frame_len := (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3]
		if _buf.size() < 4 + frame_len:
			break
		var payload := _buf.slice(4, 4 + frame_len)
		_buf = _buf.slice(4 + frame_len)
		var text := payload.get_string_from_utf8()
		Profiler.begin("parse")
		var data: Variant = JSON.parse_string(text)
		Profiler.done("parse")
		if typeof(data) == TYPE_DICTIONARY:
			if data.get("type", "") == "popup":
				latest_popup = data
			elif data.get("type", "") == "picker":
				latest_picker = data
			else:
				if latest != null:
					dropped += 1
				latest = data
	if latest != null:
		if dropped > 0:
			print("Raves: coalesced %d stale snapshot(s) this frame" % dropped)
		snapshot.emit(latest)
	if latest_popup != null:
		popup.emit(latest_popup)
	if latest_picker != null:
		picker.emit(latest_picker)

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
