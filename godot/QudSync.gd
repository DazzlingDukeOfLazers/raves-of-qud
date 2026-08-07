extends Node

## RESYNC WITH QUD (F5) — the escape hatch for a state-transition divergence.
##
## Raves infers its scene from the bridge: MainFrame watches bridge_status.txt and falls back to
## the title after three dead reads. That inference is right for the common cases and WRONG at
## every transition Qud handles with a screen of its own. Abandoning a character is the one that
## bit: Qud raises the tombstone (game summary) and stops running a game, Raves sees the bridge go
## quiet, assumes "game over -> title", and the two windows now disagree with no way back except
## clicking around in Qud.
##
## The fix is not more inference. The mod ALREADY reports Qud's real state once a second into
## qud_state.json — `live` (is a game actually running) plus `scene`, the raw _ActiveGameView
## string. Raves simply never read it. This autoload does:
##
##   * `live` decides where Raves BELONGS — it is the authoritative fact, not a guess from silence.
##   * `scene` is REPORTED, never matched against a hardcoded table of Qud view names. We know
##     "MainMenu" and "Stage"; anything else is named to the player verbatim, so a screen we have
##     never seen (tombstone, high scores, a future one) produces a useful message instead of a
##     wrong branch. This is deliberate: the tombstone's view id could only be learned by killing
##     a character, and a tool for rescuing lost states must not itself depend on a lucky guess.
##   * when Qud sits on a screen Raves cannot mirror, it offers Qud's OWN dismissal (`uiback`,
##     the first-party back command — Qud's modern screens ignore synthesised keys).
##
## Deliberately MANUAL. Auto-following Qud would fight the player during ordinary menu use and
## re-enter the game the instant a snapshot arrived; the divergence is rare and the recovery
## should be something the player asks for and can see the result of.

const STATE_TTL := 8.0        # a report older than this is stale — say so rather than act on it
const BRIDGE_PORT := 48710
const TOAST_SECONDS := 7.0

var _toast_layer: CanvasLayer = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # usable while a modal has the tree paused

## F5 anywhere. TypingGuard first: this runs in `_input`, BEFORE Godot's GUI pass, so a focused
## LineEdit has not consumed the key yet and is_input_handled() is still false — the same trap
## that made "e" open the Equipment screen while typing a note.
func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.keycode != KEY_F5:
		return
	if TypingGuard.typing(get_viewport()):
		return
	get_viewport().set_input_as_handled()
	resync()

## The support-dir path of the mod's report. Same directory contract as raves_state.json.
func _state_path() -> String:
	return InputModel.support_dir().path_join("qud_state.json")

## Qud's own report, or {} when it is missing or stale. Freshness matters more than presence: a
## crashed Qud leaves its last write behind, and acting on a corpse's state is how you end up
## driving Raves into a game that ended ten minutes ago.
func qud_report() -> Dictionary:
	var p := _state_path()
	if not FileAccess.file_exists(p):
		return {}
	var age := Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(p))
	if age > STATE_TTL:
		return {}
	var txt := FileAccess.get_file_as_string(p)
	var d = JSON.parse_string(txt)
	return d if d is Dictionary else {}

## Friendly name for a Qud view, falling back to the raw string. NOT a routing table — routing is
## `live`. This only makes the toast readable.
func _view_name(scene: String) -> String:
	match scene:
		"play", "Stage": return "the game"
		"MainMenu": return "its main menu"
		"": return "an unnamed screen"
	return "\"%s\"" % scene

func _raves_scene() -> String:
	var root := get_tree().current_scene
	return root.name if root != null else ""

## One-shot bridge command. The mod's server is multi-client, so this never disturbs the scene's
## own BridgeClient — and it works from the TITLE, where no client exists at all, which is exactly
## where a stranded player needs it.
func send_bridge(name: String, extra: Dictionary = {}) -> bool:
	var msg := {"type": "command", "name": name}
	for k in extra:
		msg[k] = extra[k]
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", BRIDGE_PORT) != OK:
		return false
	var deadline := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			var n := payload.size()
			var frame := PackedByteArray()
			frame.append((n >> 24) & 0xFF); frame.append((n >> 16) & 0xFF)
			frame.append((n >> 8) & 0xFF);  frame.append(n & 0xFF)
			frame.append_array(payload)
			peer.put_data(frame)
			peer.poll()
			peer.disconnect_from_host()
			return true
		if st == StreamPeerTCP.STATUS_ERROR:
			return false
		OS.delay_msec(20)
	peer.disconnect_from_host()
	return false

## Compare, report, and move Raves to where Qud says it belongs. Returns the message shown.
func resync() -> String:
	var d := qud_report()
	if d.is_empty():
		return _toast("No fresh report from Qud.\nIs Caves of Qud running with the Raves mod?")
	var live := bool(d.get("live", false))
	var scene := String(d.get("scene", ""))
	var here := _raves_scene()
	var view := _view_name(scene)

	if live:
		if here == "MainFrame":
			return _toast("Already in sync — Qud is in %s." % view)
		# The bridge is up and a game is running: rejoin it. Same hand-off MainMenu uses, so the
		# panels fill on arrival instead of stranding us at the "Connect (data)" prompt.
		get_tree().set_meta("holo_auto_connect", true)
		get_tree().change_scene_to_file("res://MainFrame.tscn")
		return _toast("Qud is in %s — rejoining the game." % view)

	# No game running. Raves belongs at the title; the question is whether QUD is stuck on a
	# screen of its own (the tombstone case) that the player would otherwise have to go and
	# dismiss in the other window.
	var stuck := scene != "" and scene != "MainMenu"
	if here != "MainMenu":
		get_tree().change_scene_to_file("res://MainMenu.tscn")
	if stuck:
		if not send_bridge("uiback"):
			return _toast("Qud is showing %s and no game is running.\nCould not reach the bridge to dismiss it."
				% view)
		_verify_dismissed(scene, view)
		return _toast("Qud is showing %s (no game running).\nSent its Back command…" % view)
	if here == "MainMenu":
		return _toast("Already in sync — Qud is at %s, no game running." % view)
	return _toast("No game running in Qud — returning to the title.")

## Did the Back command actually move Qud? `uiback` reaches the active window's own OnCancel/Exit,
## which covers the status screens and popups but is NOT guaranteed for every modern screen —
## ModernHighScores, measured, does not budge. A tool for un-stranding people must not report
## "sent" as if it meant "worked": watch Qud's own report for ~3s and say which happened, so the
## player either sees it clear or is told to go dismiss it in Qud instead of pressing F5 forever.
func _verify_dismissed(was: String, view: String) -> void:
	var deadline := Time.get_unix_time_from_system() + 3.0
	while Time.get_unix_time_from_system() < deadline:
		await get_tree().create_timer(0.4, true, false, true).timeout
		var now := String(qud_report().get("scene", was))
		if now != was:
			_toast("Qud left %s — now on %s." % [view, _view_name(now)])
			return
	_toast("Qud did not respond to Back and is still on %s.\nDismiss it in Qud's window; Raves is at the title." % view)

## A self-freeing toast on its own layer. FREED, never hidden: a hidden CanvasLayer still feeds
## input to its children, which is how a closed overlay went on eating Esc app-wide.
func _toast(msg: String) -> String:
	if _toast_node_valid():
		_toast_layer.queue_free()
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = 200
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(0, 40)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = QudChrome.q8(21, 23, 23)
	sb.border_color = QudChrome.q8(11, 148, 71)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = "⟳ " + msg
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)
	_toast_layer.add_child(panel)
	add_child(_toast_layer)
	var t := get_tree().create_timer(TOAST_SECONDS, true, false, true)
	t.timeout.connect(func() -> void:
		if _toast_node_valid():
			_toast_layer.queue_free()
			_toast_layer = null)
	print("[resync] ", msg.replace("\n", " "))
	return msg

func _toast_node_valid() -> bool:
	return _toast_layer != null and is_instance_valid(_toast_layer)
