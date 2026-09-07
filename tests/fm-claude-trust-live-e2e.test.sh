#!/usr/bin/env bash
# Opt-in credentialed Claude/Fable live guard for cross-clone workspace trust.
#
# The portable regression proves the repository classifier with real Git clones
# and a fake harness. This guard proves the vendor-dependent half against the
# real installed Claude Code: a Fable interactive session starts in a linked
# worktree owned by one clone after trust is registered against a second clone
# of the same origin, reaches its submitted prompt, and never renders Claude's
# workspace-trust dialog. The Claude state is copied into an isolated directory
# before registration, so no live trust entry or fleet home is changed.
#
# Run explicitly with FM_CLAUDE_TRUST_LIVE_E2E=1. This guard submits one small
# prompt to Fable and therefore spends model tokens. Refresh the workspace-trust
# record in docs/verification/runtime-backends.md from this guard after a Claude
# upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_TRUST_LIVE_E2E claude tmux git node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION=version-unknown
LABEL="Claude/Fable ($CLAUDE_VERSION)"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-trust-live.XXXXXX")
SOURCE="$LAB/source"
ORIGIN="$LAB/origin.git"
POOL_CLONE="$LAB/pool-clone"
LAUNCHING_CLONE="$LAB/secondmate-clone"
WORKTREE="$LAB/shared-pool-worktree"
CONFIG="$LAB/claude-config"
TRANSCRIPT="$LAB/pane.txt"
SOCKET="fm-claude-trust-live-$$"
SESSION=trustlive

fail_live() {
  printf 'not ok - %s: %s\n' "$LABEL" "$1" >&2
  exit 1
}

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

REAL_CONFIG=${CLAUDE_CONFIG_DIR:-${HOME:-}}
[ -n "$REAL_CONFIG" ] || fail_live "neither CLAUDE_CONFIG_DIR nor HOME locates the authenticated state"
[ -f "$REAL_CONFIG/.claude.json" ] \
  || fail_live "authenticated store '$REAL_CONFIG/.claude.json' is absent"
mkdir -p "$CONFIG"
cp "$REAL_CONFIG/.claude.json" "$CONFIG/.claude.json" \
  || fail_live "could not copy the authenticated store into the isolated lab"
if [ -f "$REAL_CONFIG/.credentials.json" ]; then
  cp "$REAL_CONFIG/.credentials.json" "$CONFIG/.credentials.json" \
    || fail_live "could not copy the authenticated credential into the isolated lab"
fi

git init -q "$SOURCE" || fail_live "could not initialize the source repository"
printf 'cross-clone trust live fixture\n' > "$SOURCE/README.md"
git -C "$SOURCE" add README.md
git -C "$SOURCE" -c user.name='Firstmate Live Test' \
  -c user.email='tests@example.invalid' commit -qm initial \
  || fail_live "could not commit the source fixture"
git clone -q --bare "$SOURCE" "$ORIGIN" \
  || fail_live "could not create the shared origin"
git clone -q "file://$ORIGIN" "$POOL_CLONE" \
  || fail_live "could not create the pool-owner clone"
git clone -q "file://$ORIGIN" "$LAUNCHING_CLONE" \
  || fail_live "could not create the secondmate clone"
git -C "$POOL_CLONE" worktree add -q -b live-cross-clone "$WORKTREE" \
  || fail_live "could not create the linked shared-pool worktree"

pool_common=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir) \
  || fail_live "could not resolve the pool worktree common dir"
launching_common=$(git -C "$LAUNCHING_CLONE" rev-parse --path-format=absolute --git-common-dir) \
  || fail_live "could not resolve the secondmate clone common dir"
[ "$pool_common" != "$launching_common" ] \
  || fail_live "the fixture accidentally shares one clone common dir"

trust_out=$(CLAUDE_CONFIG_DIR="$CONFIG" HOME="$LAB/home" \
  "$ROOT/bin/fm-claude-trust.sh" "$WORKTREE" "$LAUNCHING_CLONE" 2>&1) \
  || fail_live "cross-clone trust registration failed: $trust_out"
printf '%s\n' "$trust_out" | grep -Fqx "trusted: $WORKTREE" \
  || fail_live "registration did not report the exact leased worktree: $trust_out"
node -e '
  const fs = require("node:fs");
  const [store, worktree] = process.argv.slice(1);
  const data = JSON.parse(fs.readFileSync(store, "utf8"));
  process.exit(data.projects?.[worktree]?.hasTrustDialogAccepted === true ? 0 : 1);
' "$CONFIG/.claude.json" "$WORKTREE" \
  || fail_live "the isolated vendor store does not contain the trust entry"

PROMPT='Reply with exactly FABLE-CROSS-CLONE-TRUST-OK and do nothing else.'
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 180 -y 50 -c "$WORKTREE" \
  -- env CLAUDE_CONFIG_DIR="$CONFIG" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  claude --model fable --effort low "$PROMPT" \
  || fail_live "could not launch the real interactive harness"

i=0
budget=${FM_CLAUDE_TRUST_LIVE_POLLS:-90}
while [ "$i" -lt "$budget" ]; do
  tmux -L "$SOCKET" capture-pane -p -S -200 -t "$SESSION:0.0" > "$TRANSCRIPT" 2>/dev/null || true
  # The submitted prompt itself contains the marker once. Require its second
  # appearance, which is Fable's answer, so an echo of queued input cannot make
  # this harness-dependent check pass before the model has run.
  marker_count=$(grep -Fc 'FABLE-CROSS-CLONE-TRUST-OK' "$TRANSCRIPT" 2>/dev/null || true)
  if [ "$marker_count" -ge 2 ]; then
    break
  fi
  if grep -Fq 'Quick safety check: Is this a project you created or one you trust?' "$TRANSCRIPT" \
    || grep -Fq 'Yes, I trust this folder' "$TRANSCRIPT"; then
    fail_live "workspace-trust dialog appeared after successful pre-registration"
  fi
  if ! tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    fail_live "interactive harness exited before reaching the prompt: $(tail -12 "$TRANSCRIPT" 2>/dev/null)"
  fi
  i=$((i + 1))
  sleep 1
done

marker_count=$(grep -Fc 'FABLE-CROSS-CLONE-TRUST-OK' "$TRANSCRIPT" 2>/dev/null || true)
[ "$marker_count" -ge 2 ] \
  || fail_live "interactive prompt was not reached within ${budget}s: $(tail -12 "$TRANSCRIPT" 2>/dev/null)"
if grep -Fq 'Quick safety check: Is this a project you created or one you trust?' "$TRANSCRIPT" \
  || grep -Fq 'Yes, I trust this folder' "$TRANSCRIPT"; then
  fail_live "workspace-trust dialog appeared in the successful transcript"
fi

printf 'ok - %s accepted a cross-clone shared-pool trust registration and reached the Fable prompt without a workspace-trust dialog\n' \
  "$LABEL"
