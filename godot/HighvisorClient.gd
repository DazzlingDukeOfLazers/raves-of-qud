class_name HighvisorClient
extends RefCounted

## Talk to the highvisor daemon (localhost :48720) — the DEV-side supervisor that knows what
## screen both apps are on and how to drive between them.
##
## The wire format is the one Raves already speaks to the Qud mod on 48710: a 4-byte big-endian
## length followed by UTF-8 JSON. That is not a coincidence — highvisor's protocol.py copied it
## from the raves bridge deliberately — so this client is the mod client with a read path bolted
## on (the mod is fire-and-forget; this is request/response).
##
## EVERY CALL HERE BLOCKS. Do not call from the main thread: `gamestate` probes Qud's bridge port
## with a 0.4s connect and a 0.35s read, per app, so a "quick status check" is comfortably over a
## second of frozen game. StateGraphPanel runs these on a worker Thread and hands the result back
## with call_deferred. The blocking is deliberate rather than a polled state machine: on a worker
## thread, straight-line code that reads like the protocol is easier to keep correct than a
## resumable one, and the deadlines below bound it.
##
## The daemon is a DEVELOPMENT tool. Every failure path here returns {} rather than raising or
## logging, because the shipping game must behave as if none of this exists — see
## StateGraphPanel's dev gate.

const HOST := "127.0.0.1"
const PORT := 48720

const CONNECT_MS := 500          # the daemon is local: it answers at once or it is not there
const REPLY_MS := 8000           # gamestate does live port probes; goto/plan can be slower still
const MAX_FRAME := 32 * 1024 * 1024   # matches the daemon's own guard — refuse a nonsense length


## Is the daemon there? A connect attempt and nothing more, so the dev gate costs one handshake.
## Still blocking — worker thread only.
static func alive() -> bool:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return false
	var ok := _await_connect(peer)
	peer.disconnect_from_host()
	return ok


## One request, one response. Returns the parsed reply, or {} on ANY failure — no daemon, refused
## connection, timeout, short frame, bad JSON. The caller cannot act on the difference (all of them
## mean "no supervisor right now"), and a client that raises would take the game down with it.
static func request(op: String, extra: Dictionary = {}) -> Dictionary:
	var req := {"op": op}
	for k in extra:
		req[k] = extra[k]
	var payload := JSON.stringify(req).to_utf8_buffer()

	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return {}
	if not _await_connect(peer):
		peer.disconnect_from_host()
		return {}
	peer.set_no_delay(true)      # a request is one small frame; Nagle would just add latency

	var n := payload.size()
	var frame := PackedByteArray()
	frame.append((n >> 24) & 0xFF)
	frame.append((n >> 16) & 0xFF)
	frame.append((n >> 8) & 0xFF)
	frame.append(n & 0xFF)
	frame.append_array(payload)
	if peer.put_data(frame) != OK:
		peer.disconnect_from_host()
		return {}

	var deadline := Time.get_ticks_msec() + REPLY_MS
	var head := _read_exact(peer, 4, deadline)
	if head.size() != 4:
		peer.disconnect_from_host()
		return {}
	var want := (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3]
	if want <= 0 or want > MAX_FRAME:
		peer.disconnect_from_host()
		return {}
	var body := _read_exact(peer, want, deadline)
	peer.disconnect_from_host()
	if body.size() != want:
		return {}
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


static func _await_connect(peer: StreamPeerTCP) -> bool:
	var deadline := Time.get_ticks_msec() + CONNECT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			return true
		if st == StreamPeerTCP.STATUS_ERROR:
			return false
		OS.delay_msec(10)
	return false


## Read exactly `n` bytes, or give up at the deadline. Partial reads in a loop rather than
## `get_data(n)`: get_data blocks until it has the lot with no way out, so a daemon that accepted
## the connection and then wedged would hang this thread for the life of the process. Returning
## short is how the caller learns to give up.
static func _read_exact(peer: StreamPeerTCP, n: int, deadline: int) -> PackedByteArray:
	var out := PackedByteArray()
	while out.size() < n:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return out
		var avail := peer.get_available_bytes()
		if avail > 0:
			var res := peer.get_partial_data(mini(avail, n - out.size()))
			if res[0] != OK:
				return out
			out.append_array(res[1])
		elif Time.get_ticks_msec() > deadline:
			return out
		else:
			OS.delay_msec(10)
	return out
