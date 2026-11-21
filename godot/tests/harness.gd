extends RefCounted
## Shared runner for the headless test scenes (res://tests/test_*.tscn). Each suite keeps its own `fails`
## counter and `check(...)`; its body lives in `_run()` and its `_ready()` is just
##   func _ready() -> void:
##       Harness.run(self, _run)
## with `const Harness := preload("res://tests/harness.gd")`.
##
## Why: a GDScript runtime error (method on null, bad key ...) aborts only the function it happens in; the
## caller carries on, so a suite used to print ALL OK with the rest of that test function never run. `run`:
##   - installs a Logger for the duration of `_run()` that records every ERROR / SCRIPT ERROR / SHADER ERROR
##     the engine reports (WARNINGs are ignored), including push_error() and engine checks hit from game code;
##   - awaits `_run()` (an aborted function returns to its caller, even after an await, so control always
##     comes back here);
##   - prints "RESULT <suite>: ALL OK" only when fails == 0 and no error was recorded; otherwise
##     "RESULT <suite>: N FAILURES" (fails + recorded errors), listing the recorded errors first;
##   - quits with exit code 0 (ok) or 1 (failures).
## Errors printed after the RESULT line (engine teardown at exit: leaked RIDs / ObjectDB instances / resources
## still in use) are not counted. A suite that deliberately makes the engine or game code log an error wraps
## it in `Harness.expect_errors(true)` ... `Harness.expect_errors(false)`: plain errors logged in that window
## are reported as "expected" and not counted. SCRIPT errors always count, even in that window.
## tools/run_tests.sh runs every suite and applies the same rules to the process output.

const RESULT_PREFIX := "RESULT "


class ErrorCounter extends Logger:
	var mutex := Mutex.new()
	var errors: Array[String] = []
	var expected: Array[String] = []
	var expecting := false

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var kind := "SCRIPT ERROR" if error_type == ERROR_TYPE_SCRIPT else "ERROR"
		var where := "%s (%s:%d)" % [function, file, line]
		# Native errors raised from a script (push_error, engine checks) also carry the GDScript frame.
		if error_type != ERROR_TYPE_SCRIPT:
			for bt in script_backtraces:
				if bt != null and bt.get_frame_count() > 0:
					where += " <- %s (%s:%d)" % [bt.get_frame_function(0), bt.get_frame_file(0),
						bt.get_frame_line(0)]
					break
		var msg := "%s: %s%s at %s" % [kind, code, (" (" + rationale + ")") if rationale != "" else "", where]
		mutex.lock()
		if expecting and error_type != ERROR_TYPE_SCRIPT:
			expected.append(msg)
		else:
			errors.append(msg)
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


static var _counter: ErrorCounter


## Marks the start / end of code that is expected to log (non-script) errors, e.g. a loader fed bad input.
static func expect_errors(on: bool) -> void:
	if _counter != null:
		_counter.mutex.lock()
		_counter.expecting = on
		_counter.mutex.unlock()


static func run(suite: Node, body: Callable) -> void:
	var tree := suite.get_tree()
	var name := String(suite.get_script().resource_path).get_file().get_basename()
	_counter = ErrorCounter.new()
	OS.add_logger(_counter)
	print("HARNESS BEGIN ", name)
	await body.call()
	OS.remove_logger(_counter)
	var c := _counter
	_counter = null
	var fails := int(suite.get("fails"))
	var total := fails + c.errors.size()
	if not c.expected.is_empty():
		print("\n%s: %d expected error(s) logged" % [name, c.expected.size()])
	if not c.errors.is_empty():
		print("\n%s: %d error(s) logged during the run (each counts as a failure; a script error also means"
			% [name, c.errors.size()], " the rest of that function did not run):")
		for i in mini(c.errors.size(), 30):
			print("  ", c.errors[i])
		if c.errors.size() > 30:
			print("  ... %d more" % (c.errors.size() - 30))
	print("\n%s%s: %s" % [RESULT_PREFIX, name, "ALL OK" if total == 0 else "%d FAILURES" % total])
	tree.quit(0 if total == 0 else 1)
