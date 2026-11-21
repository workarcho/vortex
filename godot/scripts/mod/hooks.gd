extends Node
## Mod hook bus (autoload `Hooks`). The public modding API contract is rules/hooks.md: every hook name, its
## kind and its arguments are listed there.
##
## Three kinds:
## - Notifications: `Hooks.emit(name, args...)`. Listeners (`listen`) are told something happened; their return
##   value is ignored and they cannot change the outcome.
## - Filters: `Hooks.filter(name, value, args...)` returns the value after every registered filter (`add_filter`)
##   had its turn: each one receives `(value, args...)` and returns the new value. Returning `null` leaves the value
##   unchanged; returning `Hooks.CANCEL` stops the chain and the caller treats the action as cancelled (what
##   "cancelled" means is per hook, see rules/hooks.md).
## - Rules: replaceable functions (`set_rule`). `Hooks.rule(name, default, args...)` calls the override as
##   `override.call(default, args...)` (it may call `default` itself), or `default.call(args...)` without one.
##
## Order: ascending `priority` (lower first), then registration order. Deterministic for the same load order.
## Cost when nobody listens: one dictionary lookup (plus the variadic argument array).

const CANCEL := &"__hooks_cancel__"

var _listeners := {}  # StringName -> Array[Dictionary {cb, priority, owner, seq}] (sorted; replaced on change)
var _filters := {}
var _rules := {}  # StringName -> {cb, owner}
var _seq := 0
var calls := 0  # emits + filters that reached at least one callback (debug / tests)


static func is_cancel(v: Variant) -> bool:
	return typeof(v) == TYPE_STRING_NAME and v == CANCEL


# ---------------------------------------------------------------- registration

## Registers a notification listener. Returns the callable (for `unlisten`).
func listen(hook: StringName, cb: Callable, priority := 0, owner := "") -> Callable:
	_add(_listeners, hook, cb, priority, owner)
	return cb


## Registers a filter (receives `(value, args...)`, returns the new value / null / Hooks.CANCEL).
func add_filter(hook: StringName, cb: Callable, priority := 0, owner := "") -> Callable:
	_add(_filters, hook, cb, priority, owner)
	return cb


func unlisten(hook: StringName, cb: Callable) -> void:
	_remove(_listeners, hook, func(e): return e.cb == cb)


func remove_filter(hook: StringName, cb: Callable) -> void:
	_remove(_filters, hook, func(e): return e.cb == cb)


## Replaces rule `hook` (one override at a time; the last one set wins). The override receives
## `(default: Callable, args...)`.
func set_rule(hook: StringName, cb: Callable, owner := "") -> void:
	_rules[hook] = {"cb": cb, "owner": owner}


func clear_rule(hook: StringName) -> void:
	_rules.erase(hook)


## Removes every listener, filter and rule registered with `owner` (a mod id).
func remove_owner(owner: String) -> void:
	for table in [_listeners, _filters]:
		for hook in table.keys():
			_remove(table, hook, func(e): return e.owner == owner)
	for hook in _rules.keys():
		if _rules[hook].owner == owner:
			_rules.erase(hook)


## Removes everything (tests).
func clear() -> void:
	_listeners.clear()
	_filters.clear()
	_rules.clear()


func has_listeners(hook: StringName) -> bool:
	return _listeners.has(hook)


func has_filters(hook: StringName) -> bool:
	return _filters.has(hook)


func has_rule(hook: StringName) -> bool:
	return _rules.has(hook)


## Names with at least one listener / filter / rule (debug).
func active_hooks() -> Array:
	return _listeners.keys() + _filters.keys() + _rules.keys()


func _add(table: Dictionary, hook: StringName, cb: Callable, priority: int, owner: String) -> void:
	_seq += 1
	var list: Array = (table.get(hook, []) as Array).duplicate()  # copy-on-write: a running emit keeps its list
	list.append({"cb": cb, "priority": priority, "owner": owner, "seq": _seq})
	list.sort_custom(func(a, b): return a.priority < b.priority or (a.priority == b.priority and a.seq < b.seq))
	table[hook] = list


func _remove(table: Dictionary, hook: StringName, pred: Callable) -> void:
	if not table.has(hook):
		return
	var list: Array = (table[hook] as Array).filter(func(e): return not pred.call(e))
	if list.is_empty():
		table.erase(hook)
	else:
		table[hook] = list


# ---------------------------------------------------------------- calling

## Notification: every listener of `hook` is called with `args`.
func emit(hook: StringName, ...args: Array) -> void:
	var list: Variant = _listeners.get(hook)
	if list == null:
		return
	calls += 1
	for e in list:
		var cb: Callable = e.cb
		if cb.is_valid():
			cb.callv(args)


## Filter: `value` passed through every filter of `hook` in order. Returns the final value or Hooks.CANCEL.
func filter(hook: StringName, value: Variant, ...args: Array) -> Variant:
	var list: Variant = _filters.get(hook)
	if list == null:
		return value
	calls += 1
	for e in list:
		var cb: Callable = e.cb
		if not cb.is_valid():
			continue
		var out: Variant = cb.callv([value] + args)
		if out == null:
			continue
		if is_cancel(out):
			return CANCEL
		value = out
	return value


## Rule: the override if one is set (called with the default first), else the default.
func rule(hook: StringName, default: Callable, ...args: Array) -> Variant:
	var r: Variant = _rules.get(hook)
	if r == null or not (r.cb as Callable).is_valid():
		return default.callv(args)
	calls += 1
	return (r.cb as Callable).callv([default] + args)
