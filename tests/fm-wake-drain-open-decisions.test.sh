#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

test_default_mode_keeps_the_existing_bytes() {
  local dir state out expected
  dir=$(make_case default-bytes)
  state="$dir/state"
  out="$dir/drain.out"
  expected="$dir/expected.out"
  mkdir -p "$dir/home/config"
  printf 'needs-decision [key=release]: pick stable or canary\n' > "$state/task-default.status"
  {
    printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
    printf 'task-default [key=release] needs-decision: pick stable or canary\n'
    printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n"
  } > "$expected"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "default drain failed"

  cmp -s "$expected" "$out" \
    || fail "default mode changed the existing full-list bytes: $(cat "$out")"
  pass "flag-off default preserves the existing full OPEN DECISIONS output byte-for-byte"
}

test_delta_mode_reports_only_changes_and_summarizes_presentations() {
  local dir state out
  dir=$(make_case delta)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/open-decisions-delta"
  printf 'needs-decision [key=release]: pick stable or canary\n' > "$state/task-delta.status"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first delta drain failed"
  grep -F 'task-delta [key=release] needs-decision: pick stable or canary' "$out" >/dev/null \
    || fail "a fresh delta presentation did not show the full open set: $(cat "$out")"
  grep -Fx '1 open (0 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "a fresh delta presentation omitted its count and pointer: $(cat "$out")"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "unchanged delta drain failed"
  grep -Fx '1 open (1 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "an unchanged delta presentation omitted its count and pointer: $(cat "$out")"
  if grep -F 'pick stable or canary' "$out" >/dev/null; then
    fail "an unchanged decision was re-printed in delta mode: $(cat "$out")"
  fi

  printf 'needs-decision [key=release]: pick stable, canary, or both\n' >> "$state/task-delta.status"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "changed delta drain failed"
  grep -F 'task-delta [key=release] needs-decision: pick stable, canary, or both' "$out" >/dev/null \
    || fail "a changed decision did not print in delta mode: $(cat "$out")"

  printf 'blocked [key=signing]: choose a signing identity\n' >> "$state/task-delta.status"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "new delta drain failed"
  grep -F 'task-delta [key=signing] blocked: choose a signing identity' "$out" >/dev/null \
    || fail "a newly opened decision did not print in delta mode: $(cat "$out")"
  grep -Fx '2 open (1 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "a new decision produced the wrong delta summary: $(cat "$out")"

  printf 'resolved [key=signing]: use the release identity\n' >> "$state/task-delta.status"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "closed delta drain failed"
  grep -F 'task-delta [key=signing] closed (was blocked: choose a signing identity)' "$out" >/dev/null \
    || fail "a closed decision did not print in delta mode: $(cat "$out")"
  grep -Fx '1 open (1 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "a closed decision produced the wrong delta summary: $(cat "$out")"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$out" \
    || fail "full-list pointer command failed"
  grep -F 'task-delta [key=release] needs-decision: pick stable, canary, or both' "$out" >/dev/null \
    || fail "the summary's full-list command did not print every open decision: $(cat "$out")"
  pass "delta mode prints opened, changed, and closed decisions while every presentation keeps a count and full-list pointer"
}

test_delta_mode_exempts_a_lock_skipped_drain_from_the_summary() {
  local dir state out holder i=0
  dir=$(make_case delta-lock-skip)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/open-decisions-delta"
  printf 'needs-decision [key=release]: pick stable or canary\n' > "$state/task-lock.status"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.status-presentation-lock" "$dir/presentation.ready" &
  holder=$!
  while [ "$i" -lt 100 ] && [ ! -s "$dir/presentation.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/presentation.ready" ] \
    || { kill "$holder" 2>/dev/null || true; fail "presentation holder never acquired its lock"; }

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$out" \
    || { kill "$holder" 2>/dev/null || true; fail "lock-skipped delta drain failed"; }
  grep -F "STATUS PRESENTATION SKIPPED: lock remains held by live pid $holder" "$out" >/dev/null \
    || { kill "$holder" 2>/dev/null || true; fail "contended delta drain did not report its skipped presentation: $(cat "$out")"; }
  if grep -F 'open (' "$out" >/dev/null; then
    kill "$holder" 2>/dev/null || true
    fail "lock-skipped delta drain printed a summary despite presenting nothing: $(cat "$out")"
  fi

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$out" || fail "delta presentation retry failed"
  grep -Fx '1 open (0 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "presenting delta drain omitted its persistent summary: $(cat "$out")"
  pass "delta summary is required on presentations and exempt on a deliberate lock skip"
}

test_full_list_command_has_no_aggregate_byte_cap() {
  local dir state out i=0
  dir=$(make_case full-list-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/open-decisions-delta"
  while [ "$i" -lt 30 ]; do
    printf 'needs-decision [key=choice-%02d]: choose option %02d after reviewing the complete fleet context and every relevant dependency before proceeding\n' "$i" "$i" >> "$state/task-full.status"
    i=$((i + 1))
  done

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$out" \
    || fail "over-cap full-list command failed"

  grep -F 'task-full [key=choice-00]' "$out" >/dev/null \
    || fail "the full-list command omitted the first open decision: $(cat "$out")"
  grep -F 'task-full [key=choice-29]' "$out" >/dev/null \
    || fail "the full-list command omitted an open decision beyond the ordinary byte cap: $(cat "$out")"
  if grep -F 'more omitted (byte cap)' "$out" >/dev/null; then
    fail "the full-list command retained the ordinary aggregate byte cap: $(cat "$out")"
  fi
  pass "the explicit full-list command emits every open decision beyond the ordinary byte cap"
}

test_delta_mode_emits_every_over_cap_open_and_closed_entry() {
  local dir state out i=0
  dir=$(make_case delta-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/open-decisions-delta"
  while [ "$i" -lt 30 ]; do
    printf 'needs-decision [key=choice-%02d]: choose option %02d after reviewing the complete fleet context and every relevant dependency before proceeding\n' "$i" "$i" >> "$state/task-delta-cap.status"
    i=$((i + 1))
  done

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "over-cap first delta drain failed"
  grep -F 'task-delta-cap [key=choice-00]' "$out" >/dev/null \
    || fail "the first delta presentation omitted its first open decision: $(cat "$out")"
  grep -F 'task-delta-cap [key=choice-29]' "$out" >/dev/null \
    || fail "the first delta presentation omitted an open decision beyond the ordinary byte cap: $(cat "$out")"
  grep -Fx '30 open (0 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "the over-cap first delta presentation produced the wrong summary: $(cat "$out")"

  i=0
  while [ "$i" -lt 30 ]; do
    printf 'resolved [key=choice-%02d]: chose option %02d\n' "$i" "$i" >> "$state/task-delta-cap.status"
    i=$((i + 1))
  done
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "over-cap closure delta drain failed"
  grep -F 'task-delta-cap [key=choice-00] closed' "$out" >/dev/null \
    || fail "the closure delta omitted its first closed decision: $(cat "$out")"
  grep -F 'task-delta-cap [key=choice-29] closed' "$out" >/dev/null \
    || fail "the closure delta omitted a closed decision beyond the ordinary byte cap: $(cat "$out")"
  grep -Fx '0 open (0 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "the over-cap closure delta produced the wrong summary: $(cat "$out")"
  if grep -F 'more omitted (byte cap)' "$out" >/dev/null; then
    fail "delta mode retained the ordinary aggregate byte cap: $(cat "$out")"
  fi
  pass "delta mode emits every opened and closed entry beyond the ordinary byte cap"
}

test_delta_mode_summarizes_an_empty_fleet() {
  local dir state out
  dir=$(make_case delta-empty)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/open-decisions-delta"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "empty delta drain failed"

  grep -Fx '0 open (0 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "an empty delta drain omitted its persistent summary: $(cat "$out")"
  pass "delta mode prints its count and full-list pointer even when no decision is open"
}

test_delta_receipt_rejects_a_symlinked_directory_destination() {
  local dir state out staged
  dir=$(make_case delta-receipt-destination)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/home/config" "$state/receipt-target"
  : > "$dir/home/config/open-decisions-delta"
  ln -s receipt-target "$state/.open-decisions-presentation"
  printf 'needs-decision [key=release]: pick stable or canary\n' > "$state/task-receipt.status"

  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>&1 \
    || fail "drain failed while rejecting a symlinked receipt destination"
  [ -L "$state/.open-decisions-presentation" ] \
    || fail "the failed receipt commit replaced its symlinked destination"
  staged=$(find "$state" -maxdepth 1 -name '.open-decisions-presentation.*' -print -quit)
  [ -z "$staged" ] || fail "the failed receipt commit leaked its staged file: $staged"
  staged=$(find "$state/receipt-target" -mindepth 1 -maxdepth 1 -print -quit)
  [ -z "$staged" ] || fail "the failed receipt commit moved its staged file into the destination directory: $staged"

  rm -f "$state/.open-decisions-presentation"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "delta drain did not recover after removing the invalid receipt destination"
  grep -F 'task-receipt [key=release] needs-decision: pick stable or canary' "$out" >/dev/null \
    || fail "a failed receipt commit incorrectly acknowledged the first presentation: $(cat "$out")"
  grep -Fx '1 open (0 unchanged) - full list: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "recovery from an invalid receipt destination produced the wrong summary: $(cat "$out")"
  pass "delta receipt commit rejects directory symlinks and cleans its staged state"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_buried_decision_still_surfaces
test_default_mode_keeps_the_existing_bytes
test_delta_mode_reports_only_changes_and_summarizes_presentations
test_delta_mode_exempts_a_lock_skipped_drain_from_the_summary
test_full_list_command_has_no_aggregate_byte_cap
test_delta_mode_emits_every_over_cap_open_and_closed_entry
test_delta_mode_summarizes_an_empty_fleet
test_delta_receipt_rejects_a_symlinked_directory_destination
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
