#!/usr/bin/env bash
set -u

ROOT=/home/tommy/.no-mistakes/worktrees/8c893aaef187/01M1XAQVJYFH621W70AY1CEAPQ
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fable-secondmate-cross-clone-evidence)
case_dir="$TMP_ROOT/scenario"
home="$case_dir/secondmate-home"
owner="$case_dir/pool-owner-project"
project="$home/projects/project"
worktree="$case_dir/shared-pool-worktree"
config="$case_dir/claude-config"
launch_log="$case_dir/launch.log"
mkdir -p "$config"

fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_test_spawn_home "$home" claude
fm_git_worktree "$owner" "$worktree" wt-fable-cross-clone-evidence
git clone -q "$(git -C "$owner" remote get-url origin)" "$project"
fm_test_spawn_brief "$home" fablecrosscloneevidence

worktree_common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)
project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir)
worktree_origin=$(git -C "$worktree" remote get-url origin)
project_origin=$(git -C "$project" remote get-url origin)

before_trust="$case_dir/fm-claude-trust-before.sh"
git -C "$ROOT" show 6d396da7c43f03315873332b2591119a8c780a97:bin/fm-claude-trust.sh > "$before_trust"
chmod +x "$before_trust"
before_output=$(CLAUDE_CONFIG_DIR="$config" HOME="$case_dir/home-before" \
  "$before_trust" "$worktree" "$project" 2>&1)
before_status=$?

spawn_output=$(FM_TEST_CLAUDE_CONFIG_DIR="$config" FM_FAKE_LAUNCH_LOG="$launch_log" \
  fm_test_run_spawn "$home" "$worktree" "$fakebin" fablecrosscloneevidence "$project" claude \
  --model fable --mode no-mistakes --yolo off)
spawn_status=$?

trusted=$(node -e '
const fs = require("node:fs");
const store = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const record = store.projects?.[process.argv[2]];
process.stdout.write(record?.hasTrustDialogAccepted === true ? "true" : "false");
' "$config/.claude.json" "$worktree")
launch_command=$(tail -n 1 "$launch_log")

printf 'Scenario: Fable spawn from a secondmate home into a shared-pool worktree\n'
printf 'Launching checkout common-dir: %s\n' "$project_common"
printf 'Leased worktree common-dir:   %s\n' "$worktree_common"
printf 'Distinct clone identities:    %s\n' "$([ "$worktree_common" != "$project_common" ] && printf yes || printf no)"
printf 'Matching origin identity:     %s\n' "$([ "$worktree_origin" = "$project_origin" ] && printf yes || printf no)"
printf 'Base trust-helper exit status: %s\n' "$before_status"
printf 'Base trust-helper output:\n%s\n' "$before_output"
printf 'fm-spawn exit status:         %s\n' "$spawn_status"
printf 'Claude trust persisted:       %s\n' "$trusted"
printf 'Requested Fable model kept:   %s\n' "$(printf '%s\n' "$launch_command" | grep -Fq -- "--model 'fable'" && printf yes || printf no)"
printf 'Launch brief delivered:       %s\n' "$(printf '%s\n' "$launch_command" | grep -Fq -- "$home/data/fablecrosscloneevidence/launch-brief.md" && printf yes || printf no)"
printf 'Spawn output:\n%s\n' "$spawn_output"
printf 'Launch command:\n%s\n' "$launch_command"

[ "$worktree_common" != "$project_common" ] || exit 1
[ "$worktree_origin" = "$project_origin" ] || exit 1
[ "$before_status" -ne 0 ] || exit 1
[ "$spawn_status" -eq 0 ] || exit 1
[ "$trusted" = true ] || exit 1
printf '%s\n' "$launch_command" | grep -Fq -- "--model 'fable'" || exit 1
printf '%s\n' "$launch_command" | grep -Fq -- "$home/data/fablecrosscloneevidence/launch-brief.md" || exit 1
