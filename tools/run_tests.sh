#!/usr/bin/env bash
# Runs the headless test suites (godot/tests/test_*.tscn) and prints a summary.
#
# Usage (from anywhere):
#   tools/run_tests.sh                 # every suite
#   tools/run_tests.sh power run qol   # only these (names with or without the test_ prefix)
#   TEST_TIMEOUT=600 tools/run_tests.sh
#   KEEP_LOGS=1 tools/run_tests.sh     # keep per-suite logs even when they pass
# Logs: work/test_logs/<suite>.log (failing suites' logs are always kept). Exit code 0 only if every suite passed.
#
# A suite FAILS when any of these holds:
#   - it timed out (TEST_TIMEOUT seconds, default 300) or exited with a non-zero code;
#   - a test script failed to load (parse error; the suite is stopped at once instead of hanging until the timeout);
#   - its last result line is not "ALL OK" (suites on tests/harness.gd print "RESULT <suite>: ALL OK");
#   - the output contains "SCRIPT ERROR" anywhere (script errors are never benign, even at exit);
#   - an "ERROR:" / "SHADER ERROR" line appears before the result line. For harness suites only the lines before
#     the harness started count here ("ERROR:" during the run is already counted by the harness, which honours
#     Harness.expect_errors). Lines after the result line are engine teardown (leaked RIDs, ObjectDB instances,
#     resources still in use at exit) and are ignored. WARNING lines are always ignored.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
TIMEOUT="${TEST_TIMEOUT:-300}"
LOGDIR="$ROOT/work/test_logs"
mkdir -p "$LOGDIR"

suites=()
if [ $# -gt 0 ]; then
	for a in "$@"; do
		a="${a#test_}"; a="${a%.tscn}"
		suites+=("test_$a")
	done
else
	for f in "$ROOT"/godot/tests/test_*.tscn; do
		suites+=("$(basename "$f" .tscn)")
	done
fi

passed=0
failed=()
start_all=$(date +%s)
for s in "${suites[@]}"; do
	log="$LOGDIR/$s.log"
	if [ ! -f "$ROOT/godot/tests/$s.tscn" ]; then
		failed+=("$s: no such suite")
		printf '%-28s FAIL  no such suite\n' "$s"
		continue
	fi
	t0=$(date +%s)
	timeout "$TIMEOUT" "$GODOT" --headless --path "$ROOT/godot" "res://tests/$s.tscn" >"$log" 2>&1 &
	pid=$!
	# A suite whose script fails to parse never quits: stop it at once instead of waiting for the timeout.
	parse_err=0
	while kill -0 "$pid" 2>/dev/null; do
		if grep -q "Failed to load script \"res://tests/" "$log" 2>/dev/null; then
			parse_err=1
			kill "$pid" 2>/dev/null
			break
		fi
		sleep 1
	done
	wait "$pid"
	rc=$?
	[ $parse_err -eq 1 ] && rc=125
	dt=$(( $(date +%s) - t0 ))
	reasons=()
	if [ $rc -eq 125 ]; then
		reasons+=("script failed to load (parse error), stopped")
	elif [ $rc -eq 124 ]; then
		reasons+=("timeout after ${TIMEOUT}s")
	elif [ $rc -ne 0 ]; then
		reasons+=("exit code $rc")
	fi
	# Result line: the harness's "RESULT <suite>: ..." line, else (suites not on the harness) the last line
	# mentioning ALL OK / FAILURES.
	res_ln=$(grep -n "^RESULT $s: " "$log" | tail -1 | cut -d: -f1)
	harness=1
	if [ -z "$res_ln" ]; then
		harness=0
		res_ln=$(grep -n "ALL OK\|[0-9] FAILURES" "$log" | tail -1 | cut -d: -f1)
	fi
	if [ -z "$res_ln" ]; then
		reasons+=("no result line (crashed or aborted)")
		res_ln=$(wc -l <"$log")
	else
		res_text=$(sed -n "${res_ln}p" "$log")
		case "$res_text" in
			*"ALL OK"*) ;;
			*) reasons+=("$(echo "$res_text" | sed 's/^RESULT //')") ;;
		esac
	fi
	n_script=$(grep -c "SCRIPT ERROR" "$log")
	[ "$n_script" -gt 0 ] && reasons+=("$n_script SCRIPT ERROR line(s)")
	# ERROR lines that the harness did not see: before it started (harness suites) or before the result line.
	if [ $harness -eq 1 ]; then
		begin_ln=$(grep -n "^HARNESS BEGIN" "$log" | head -1 | cut -d: -f1)
		limit=${begin_ln:-$res_ln}
	else
		limit=$res_ln
	fi
	n_err=$(head -n "$limit" "$log" | grep -c "^ERROR:\|^SHADER ERROR")
	[ "$n_err" -gt 0 ] && reasons+=("$n_err ERROR line(s) before the run's result")
	if [ ${#reasons[@]} -eq 0 ]; then
		passed=$((passed + 1))
		printf '%-28s ok    %3ss%s\n' "$s" "$dt" "$([ $harness -eq 0 ] && echo '  (not on tests/harness.gd)')"
		[ -z "${KEEP_LOGS:-}" ] && rm -f "$log"
	else
		msg=$(printf '%s; ' "${reasons[@]}"); msg="${msg%; }"
		failed+=("$s: $msg")
		printf '%-28s FAIL  %3ss  %s\n' "$s" "$dt" "$msg"
	fi
done

echo
echo "$passed / ${#suites[@]} suites passed in $(( $(date +%s) - start_all ))s"
if [ ${#failed[@]} -gt 0 ]; then
	echo "FAILED (logs in work/test_logs/):"
	for f in "${failed[@]}"; do echo "  $f"; done
	exit 1
fi
exit 0
