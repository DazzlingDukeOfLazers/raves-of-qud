class_name Profiler
extends RefCounted

## Dead-simple accumulating profiler for the per-turn path, so we can Pareto the
## longest delays. Fully static — any file calls Profiler.begin("x") / .done("x")
## without threading an instance around. F9 in the viewer writes report() to
## RavesOfQud/profile.txt (Claude reads it), then resets.

static var enabled := true
static var _acc := {}     # name -> [total_us, count, max_us]
static var _open := {}    # name -> start_us

static func begin(n: String) -> void:
	if enabled:
		_open[n] = Time.get_ticks_usec()

static func done(n: String) -> void:
	if not enabled or not _open.has(n):
		return
	_record(n, Time.get_ticks_usec() - int(_open[n]))
	_open.erase(n)

## Record a duration measured elsewhere (e.g. the mod's serialize time in serverMs).
static func add_us(n: String, us: int) -> void:
	if enabled and us > 0:
		_record(n, us)

static func _record(n: String, dt: int) -> void:
	var e: Array = _acc.get(n, [0, 0, 0])
	e[0] += dt
	e[1] += 1
	e[2] = maxi(e[2], dt)
	_acc[n] = e

static func reset() -> void:
	_acc.clear()
	_open.clear()

## Pareto report: phases sorted by total time spent, with each phase's share.
static func report() -> String:
	var names := _acc.keys()
	names.sort_custom(func(a, b): return _acc[a][0] > _acc[b][0])
	var grand := 0
	for n in names:
		grand += _acc[n][0]
	var turns: int = int(_acc.get("render", [0, 0, 0])[1])
	var s := "== Raves profiler — by total time (Pareto) ==\n"
	s += "sampled %d turns\n\n" % turns
	s += "%-16s %10s %8s %8s %6s %7s\n" % ["phase", "total", "avg", "max", "n", "share"]
	for n in names:
		var e: Array = _acc[n]
		s += "%-16s %8.1fms %6.2fms %6.2fms %6d %6.1f%%\n" % [
			n, e[0] / 1000.0, e[0] / 1000.0 / maxi(e[1], 1), e[2] / 1000.0,
			e[1], 100.0 * e[0] / maxi(grand, 1)]
	return s
