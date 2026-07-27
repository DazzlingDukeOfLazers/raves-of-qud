extends Node

## Direction picker — extracted from Main. Qud's PickDirection blocks the turn thread waiting for a
## LeftClick at a CELL (it derives the direction). We show the prompting ability's icon as a cursor over
## the Holodeck; clicking an ADJACENT tile sends that cell (the mod injects the click), while a
## non-adjacent click / right-click / Esc cancels (the mod injects a RightClick so Qud UNBLOCKS). Only
## started for abilities that actually prompt, else Qud would freeze waiting.
##
## Stage 5 of the Main.gd decomposition. Main drives update_cursor() from _process and handle_input() from
## _input; MainFrame kicks it off via Main.start_direction_picker(). Depends on the CameraRig (the
## mouse->cell raycast + the player cell) and the bridge client (to send dir / dircancel).

var _cam_rig                # CameraRig: _cam (raycast), zstretch(), _player
var _client                 # BridgeClient: send_command("dir"/"dircancel", …)
var _picking := false
var _pick_layer: CanvasLayer
var _pick_icon: TextureRect
var _pick_x: Label
var _pick_hint: Label

func setup(cam_rig, client) -> void:
	_cam_rig = cam_rig
	_client = client

func is_picking() -> bool:
	return _picking

## Begin picking with `icon` as the on-tile cursor. Builds the overlay lazily on first use.
func start(icon: Texture2D) -> void:
	if _pick_layer == null:
		_pick_layer = CanvasLayer.new()
		_pick_layer.layer = 50   # above the frame chrome
		add_child(_pick_layer)
		_pick_icon = TextureRect.new()
		_pick_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_pick_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_pick_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pick_icon.size = Vector2(64, 96)   # full-size, to sit on the tile
		_pick_layer.add_child(_pick_icon)
		_pick_x = Label.new()
		_pick_x.text = "✗"
		_pick_x.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
		_pick_x.add_theme_font_size_override("font_size", 44)
		_pick_x.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pick_layer.add_child(_pick_x)
		_pick_hint = Label.new()
		_pick_hint.add_theme_font_size_override("font_size", UiFont.px(get_viewport(), "title"))
		_pick_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		_pick_hint.position = Vector2(16, 8)
		_pick_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pick_layer.add_child(_pick_hint)
	_pick_icon.texture = icon
	_pick_hint.text = "Pick a direction — click an adjacent tile   (right-click / Esc to cancel)"
	_picking = true
	_pick_layer.visible = true

## The zone cell under a screen point, via a ray to the ground plane (accounts for the top-down Z-stretch).
## Returns a sentinel when it can't resolve.
func _pick_cell(mp: Vector2) -> Vector2i:
	if _cam_rig._cam == null:
		return Vector2i(-9999, -9999)
	var o: Vector3 = _cam_rig._cam.project_ray_origin(mp)
	var d: Vector3 = _cam_rig._cam.project_ray_normal(mp)
	if absf(d.y) < 0.0001:
		return Vector2i(-9999, -9999)
	var t := -o.y / d.y
	if t <= 0.0:
		return Vector2i(-9999, -9999)
	var hit := o + d * t
	var zs: float = _cam_rig.zstretch()
	return Vector2i(int(round(hit.x)), int(round(hit.z / maxf(zs, 0.001))))

func _player_cell() -> Vector2i:
	return Vector2i(int(round(_cam_rig._player.x)), int(round(_cam_rig._player.z)))

## Valid = one of the 8 tiles AROUND the player (not the player's own tile, not further). Those snap;
## everything else is the freeform "✗".
func _pick_is_adjacent(c: Vector2i) -> bool:
	if c.x < -9000:
		return false
	var p := _player_cell()
	var dx := c.x - p.x
	var dy := c.y - p.y
	return (dx != 0 or dy != 0) and maxi(absi(dx), absi(dy)) == 1

func update_cursor() -> void:
	if not _picking or _pick_icon == null:
		return
	var mp := get_viewport().get_mouse_position()
	var c := _pick_cell(mp)
	if _pick_is_adjacent(c):
		# SNAP the icon onto the adjacent tile at FULL (tile) size: project the cell's ground point and a
		# point one tile-sprite tall (16x24 -> 1.5 world units) above it; the pixel gap is the on-screen
		# tile height, so the icon matches the rendered tiles at any zoom. Stands on the tile.
		var zs: float = _cam_rig.zstretch()
		var base: Vector2 = _cam_rig._cam.unproject_position(Vector3(c.x, 0.0, c.y * zs))
		var top: Vector2 = _cam_rig._cam.unproject_position(Vector3(c.x, 1.5, c.y * zs))
		var ph := maxf(28.0, absf(base.y - top.y))
		_pick_icon.size = Vector2(round(ph * 16.0 / 24.0), round(ph))
		_pick_icon.position = Vector2(base.x - _pick_icon.size.x / 2.0, base.y - _pick_icon.size.y)
		_pick_icon.visible = true
		_pick_x.visible = false
	else:
		# Outside the valid ring: the ✗ follows the mouse freeform.
		_pick_x.position = mp - Vector2(14, 28)
		_pick_x.visible = true
		_pick_icon.visible = false

func _end() -> void:
	_picking = false
	if _pick_layer != null:
		_pick_layer.visible = false
	# hand keyboard focus back to nothing, so the movement arrows reach the Holodeck's _unhandled_input
	# again (a UI control that grabbed focus to start the ability would otherwise keep swallowing them).
	if is_inside_tree():
		get_viewport().gui_release_focus()

func _cancel() -> void:
	if _client != null:
		_client.send_command("dircancel", {})   # unblock Qud's prompt
	_end()

## Handle input while the picker is up. Returns true if the event was consumed.
func handle_input(event: InputEvent) -> bool:
	if not _picking:
		return false
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var c := _pick_cell(event.position)
			if _pick_is_adjacent(c) and _client != null:
				_client.send_command("dir", {"x": str(c.x), "y": str(c.y)})
				_end()
			else:
				_cancel()   # clicked out of range -> cancel so Qud doesn't stay blocked
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel()
			return true
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel()
		return true
	# swallow other input while picking, so a stray key can't move/act mid-prompt
	if event is InputEventKey and event.pressed and not event.echo:
		return true
	return false
