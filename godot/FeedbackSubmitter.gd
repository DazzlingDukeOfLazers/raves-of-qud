extends Node
class_name FeedbackSubmitter

## VENDORED from the feedback-service repo (client/godot/FeedbackSubmitter.gd), which is the
## canonical copy. Raves is its first consumer; per that repo's decision doc the client gets
## EXTRACTED into a shared addon on the SECOND product that needs it, not speculatively on the
## first. Fix bugs there and re-copy, so the two do not drift apart quietly.

## Drains a feedback outbox to a feedback-service endpoint. Engine-side half of
## ../../schema/envelope.v1.md.
##
## THE OUTBOX IS THE SOURCE OF TRUTH, NOT THIS. Games run offline, on aeroplanes, behind captive
## portals and on machines where the endpoint is simply down. A report that exists only in flight
## is a report that can be lost, so nothing here deletes a line until the server has acknowledged
## it — and a line that is refused as BAD is marked, not silently dropped, because "the server
## rejected all my feedback" should be answerable afterwards.
##
## Drop it in as an autoload, point `outbox_path` at the JSONL the feedback tool writes, and call
## `flush()` whenever you like — app start, a timer, or after a report is filed. Concurrent flushes
## are refused rather than queued: two drains racing over one file is how duplicates are born.

signal finished(sent: int, discarded: int, failed: int)

## No trailing slash. Empty disables submission entirely — the outbox still accumulates, which is
## the correct behaviour for a build that ships before the service exists.
@export var endpoint := ""
@export var outbox_path := ""
## Reports the server refused as malformed. Kept, never deleted: see the note above.
@export var rejected_suffix := ".rejected"
@export var timeout_seconds := 20.0

var _busy := false


func flush() -> void:
	if _busy or endpoint == "" or outbox_path == "":
		return
	if not FileAccess.file_exists(outbox_path):
		return
	_busy = true
	# `_flush.call_deferred()` — the CALLABLE, deferred. `_flush().call_deferred()` calls the
	# coroutine first and then asks its void return value to defer itself, which does not parse.
	_flush.call_deferred()


func _flush() -> void:
	var lines := _read_lines(outbox_path)
	var keep: Array[String] = []
	var rejected: Array[String] = []
	var sent := 0
	var discarded := 0
	var failed := 0
	var limited := false

	for line in lines:
		if limited:
			keep.append(line)
			continue
		var rec: Variant = JSON.parse_string(line)
		if not (rec is Dictionary):
			# Not our record. Keep it verbatim — this file belongs to the app, not to us.
			keep.append(line)
			continue
		var res := await _post_report(rec as Dictionary)
		match res.get("kind", "fail"):
			"sent":
				sent += 1
				var shot := str((rec as Dictionary).get("shot", ""))
				if shot != "" and bool(res.get("image_accepted", false)):
					await _put_image(str(res.get("id", "")), shot)
			"discarded":
				# A [deleteme] report. Accepted and thrown away by design; dropping the line is the
				# whole point, and retrying it forever would be the bug.
				discarded += 1
			"limited":
				# Hold this one and everything after it: the window is per minute, so the rest of
				# the queue would only collect 429s too. Position in the file is preserved.
				keep.append(line)
				failed += 1
				limited = true
			"rejected":
				rejected.append(line)
				failed += 1
			_:
				# Transport or 5xx: the report is fine, the world is not. Hold it.
				keep.append(line)
				failed += 1

	_write_lines(outbox_path, keep)
	if not rejected.is_empty():
		_append_lines(outbox_path + rejected_suffix, rejected)
	_busy = false
	finished.emit(sent, discarded, failed)


## {kind: sent|discarded|rejected|fail, id, image_accepted}
func _post_report(rec: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_seconds
	add_child(http)
	var err := http.request(endpoint + "/v1/report", ["content-type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(rec))
	if err != OK:
		http.queue_free()
		return {"kind": "fail"}
	var r: Array = await http.request_completed
	http.queue_free()
	var code := int(r[1])
	var body: Variant = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
	# 429 IS NOT A REJECTION. It is the one 4xx that means "later", and lumping it in with the
	# permanent ones threw 26 perfectly good reports into .rejected on the first real drain --
	# valid envelopes the server accepted by hand seconds afterwards. The flush STOPS here rather
	# than hammering out the rest of the queue against a limiter that has already said no.
	if code == 429:
		return {"kind": "limited"}
	if code == 200 or code == 202:
		if body is Dictionary and bool((body as Dictionary).get("discarded", false)):
			return {"kind": "discarded"}
		var id := str((body as Dictionary).get("id", "")) if body is Dictionary else ""
		var img := bool((body as Dictionary).get("image_accepted", false)) if body is Dictionary else false
		return {"kind": "sent", "id": id, "image_accepted": img}
	# 4xx means THIS REPORT will never be accepted, so retrying it blocks the queue behind it
	# forever. 5xx and 503 mean try later. That distinction is the reason the server bothers to
	# return meaningful statuses at all.
	if code >= 400 and code < 500:
		return {"kind": "rejected"}
	return {"kind": "fail"}


func _put_image(id: String, rel_shot: String) -> void:
	if id == "":
		return
	var path := outbox_path.get_base_dir().path_join(rel_shot)
	if not FileAccess.file_exists(path):
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return
	var http := HTTPRequest.new()
	http.timeout = timeout_seconds
	add_child(http)
	# The image is BEST EFFORT and deliberately not retried: the note is the report, and a failed
	# picture must never hold back the queue or resurrect a line that was already accepted.
	var err := http.request_raw(endpoint + "/v1/report/" + id + "/image",
		["content-type: image/png"], HTTPClient.METHOD_PUT, bytes)
	if err != OK:
		http.queue_free()
		return
	await http.request_completed
	http.queue_free()


func _read_lines(path: String) -> Array[String]:
	var out: Array[String] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "":
			out.append(line)
	f.close()
	return out


func _write_lines(path: String, lines: Array[String]) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	for l in lines:
		f.store_line(l)
	f.close()


func _append_lines(path: String, lines: Array[String]) -> void:
	var f: FileAccess
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	for l in lines:
		f.store_line(l)
	f.close()
