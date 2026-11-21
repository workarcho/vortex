class_name GameClock
extends RefCounted
## FTL's clock (rules/timing_and_projectiles.md): everything advances by a per-frame "factor".

const BASE := 16.0
const MAX_FACTOR := 0.5


static func factor(delta_seconds: float, speed_level := 0) -> float:
	return minf(delta_seconds * (BASE + 7.0 * speed_level), MAX_FACTOR)
