#!/usr/bin/env bash
# E2E-10: Agent Workpad Protocol round-trip (SPEC §11.8).
#
# 1. Swap WORKFLOW.md for a workpad-enabled variant (built per-run from
#    workflow.smoke.md + WORKFLOW.workpad.example.md fragments — both the
#    `agent.workpad` config block AND the prompt-template section that
#    references {{ thread_id }}/prior_sessions are injected).
# 2. Create a fresh issue with AGENT PRIORITY INSTRUCTIONS to post a v1
#    workpad comment containing the orchestrator-supplied {{ thread_id }},
#    {{ model }}, etc.
# 3. Set Status → Agent Ready. Wait for orchestrator dispatch + workpad
#    marker on the issue.
# 4. Flip Status → Done (terminal reconcile), then Rework (re-dispatch).
# 5. Wait for the SECOND `Dispatching` log line for this issue, then read
#    the corresponding Codex rollout JSONL and confirm the FIRST session's
#    thread_id (sourced from the orchestrator log's `session_id=` field,
#    NOT from the agent's comment body) appears in the second prompt's
#    `Prior sessions` rendering.
#
# §11.8.8 truthfulness: the agent's workpad body is best-effort and may
# contain placeholder/`unknown` values when the smoke-mode model fails to
# bind `{{ thread_id }}`. The orchestrator's §13.1 structured log is the
# authoritative session history, so verification reads thread_id from
# `session_id=<thread_id>-<turn_id>` lines in `elixir/log/symphony.log.*`.
#
# Requires a capable model to follow the in-prompt workpad instruction. The
# smoke-mode workflow uses gpt-5.4-mini at minimal reasoning which usually
# ignores instructions. Override via SYMPHONY_E2E_E2E10_MODEL /
# SYMPHONY_E2E_E2E10_REASON env vars.

set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

MODEL="${SYMPHONY_E2E_E2E10_MODEL:-gpt-5.5}"
REASON="${SYMPHONY_E2E_E2E10_REASON:-low}"
MAX_TURNS="${SYMPHONY_E2E_E2E10_MAX_TURNS:-2}"

# Build the per-case WORKFLOW.md by augmenting workflow.smoke.md with the
# workpad config block + prompt section + a stronger model. We write
# directly into the canonical WORKFLOW.md slot (run.sh has already swapped
# the smoke variant in) and restore on EXIT.
WORKFLOW="$E2E_ELIXIR_DIR/WORKFLOW.md"
BACKUP="$WORKFLOW.e2e10_bak"
cp "$WORKFLOW" "$BACKUP"

# Install restore trap BEFORE any destructive mutation. If sed/awk fail
# under `set -euo pipefail`, the trap still restores WORKFLOW.md.
cleanup_e2e10() {
  if [[ -f "$BACKUP" ]]; then
    mv "$BACKUP" "$WORKFLOW"
  fi
  rm -f "$WORKFLOW.tmp" "$WORKFLOW.aug"
}
trap cleanup_e2e10 EXIT

# Transform: enable workpad, force codex model, tighten max_turns, raise
# reasoning_effort. We don't need the agent to push code — only to post
# the marker comment and exit.
sed -i.tmp -E \
  -e "s|^( *max_turns:).*|\\1 $MAX_TURNS|" \
  -e "s|codex --config shell_environment_policy.inherit=all --config 'model=\"[^\"]+\"' --config model_reasoning_effort=[a-z]+ app-server|codex --config shell_environment_policy.inherit=all --config 'model=\"$MODEL\"' --config model_reasoning_effort=$REASON app-server|" \
  "$WORKFLOW"
rm -f "$WORKFLOW.tmp"

# Inject `workpad: enabled: true` under `agent:` and `model: "$MODEL"`
# under `codex:`. We do this with awk so we can place the lines at the
# correct indentation regardless of what the smoke file looked like.
awk -v model="$MODEL" '
  BEGIN { injected_workpad = 0; injected_model = 0 }
  /^agent:$/ { print; next }
  /^codex:$/ {
    if (!injected_workpad) {
      print "  workpad:"
      print "    enabled: true"
      print "    version: v1"
      print "    max_sessions_visible: 20"
      print "    update_throttle_turns: 3"
      injected_workpad = 1
    }
    print
    print "  model: \"" model "\""
    injected_model = 1
    next
  }
  { print }
' "$WORKFLOW" > "$WORKFLOW.aug"
mv "$WORKFLOW.aug" "$WORKFLOW"

# Append the workpad PROMPT section so the agent actually sees
# `{{ thread_id }}` / `{{ prior_sessions }}` substitutions. Without this,
# prompt_builder emits the workpad vars but the template never renders
# them and the agent guesses literal "unknown".
cat >>"$WORKFLOW" <<'WORKPAD_PROMPT'

## Agent Workpad Protocol (SPEC §11.8)

You have a cross-session workpad — a single GitHub Issue/PullRequest comment
identified by an HTML marker. Manage it via the `github_graphql` tool.

**On first turn, append your row to the sessions table:**

| `{{ thread_id }}` | {{ attempt }} | {{ dispatched_at }} | {{ model }} |

{% if prior_sessions %}
**Prior sessions** (most recent first; orchestrator-authoritative — do not invent values):

{% for s in prior_sessions %}
- `{{ s.thread_id }}` attempt={{ s.attempt }} dispatched={{ s.dispatched_at }} model={{ s.model }} stop_reason={{ s.stop_reason }}
{% endfor %}
{% endif %}
WORKPAD_PROMPT

# Assert the awk transform actually fired. If the smoke workflow ever
# changes its YAML top-level anchors (e.g. indented under another block),
# the awk pass silently no-ops and e2e-10 would run with the wrong config.
grep -q '^  workpad:$' "$WORKFLOW" || e2e::verdict_fail \
  "WORKFLOW augmentation failed: workpad: block not injected (smoke YAML changed?)"
grep -q "^  model: \"$MODEL\"\$" "$WORKFLOW" || e2e::verdict_fail \
  "WORKFLOW augmentation failed: codex.model not injected"
grep -q "Agent Workpad Protocol (SPEC §11.8)" "$WORKFLOW" || e2e::verdict_fail \
  "WORKFLOW augmentation failed: workpad prompt section not appended"

ORCH_LOG="$E2E_LOG_DIR/run.log"
e2e::start_orchestrator "$ORCH_LOG"

# Capture the timestamp BEFORE creating the issue so we can later filter
# the orchestrator's symphony.log to events after this run started.
RUN_START_EPOCH=$(date +%s)

# Create issue with placeholder body; we edit the body to include the
# just-created node id for the AGENT PRIORITY INSTRUCTION.
read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-10 workpad roundtrip" \
  "placeholder — will edit body below")

# The workpad-enabled prompt template already instructs the agent to find
# or create a workpad comment via `addComment` with the v1 marker. The
# body below adds an explicit priority instruction so the smoke-mode
# model (which usually ignores templates) does the right thing. The agent
# is told to use the orchestrator-supplied {{ thread_id }} verbatim; if it
# writes `unknown` instead, that is a §11.8.8 truthfulness violation that
# the orchestrator-log cross-check below will catch.
BODY="Smoke test. AGENT PRIORITY INSTRUCTION: Post a single comment to this issue via the github_graphql tool. The comment body MUST begin with the line:

<!-- symphony-workpad:v1 -->

and include a sessions table row containing the orchestrator-provided thread_id, dispatched_at, and model values from your prompt context. After posting the comment, end the turn immediately. Do not make code changes. Use this exact mutation shape (substitute real values):

\`\`\`
mutation {
  addComment(input:{
    subjectId:\"$ISSUE_NODE_ID\",
    body:\"<!-- symphony-workpad:v1 -->\\n| thread_id | attempt | dispatched_at | model |\\n|---|---|---|---|\\n| <THREAD_ID> | <ATTEMPT> | <DISPATCHED_AT> | <MODEL> |\\n<!-- /symphony-workpad:v1 -->\"
  }) { commentEdge { node { id } } }
}
\`\`\`"
gh issue edit "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --body "$BODY" >/dev/null

ITEM_ID=$(e2e::add_to_project "$ISSUE_NODE_ID")
e2e::set_status "$ITEM_ID" "Agent Ready"
echo "issue=$ISSUE_NUM item=$ITEM_ID model=$MODEL max_turns=$MAX_TURNS"

IDENT="$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO#$ISSUE_NUM"
e2e::wait_for_log_line "Dispatching issue to agent.*$IDENT" 60 || \
  e2e::verdict_fail "never dispatched first time"

# Poll the issue comments until a v1 workpad marker appears (~150s budget).
# The marker is REQUIRED — without it, the round-trip has nothing to round.
elapsed=0
marker_body=""
while (( elapsed < 150 )); do
  comments_json=$(gh issue view "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --json comments 2>/dev/null || echo '{}')
  marker_body=$(jq -r '.comments[]?.body | select(. != null) | select(contains("<!-- symphony-workpad:v1 -->"))' <<<"$comments_json" | awk 'NR==1{print; exit}')
  if [[ -n "$marker_body" ]]; then
    break
  fi
  sleep 5
  (( elapsed+=5 ))
done

if [[ -z "$marker_body" ]]; then
  e2e::verdict_partial "no v1 workpad marker on issue within 150s — agent did not post workpad. Likely smoke-mode model ignored instructions."
fi

echo "first_workpad_body_head=$(printf '%s' "$marker_body" | awk 'NR==1{printf "%.200s", $0; exit}')"

# Wait for first turn to exit cleanly.
e2e::wait_for_log_line "worker stop reason=:agent_exit_normal issue_id=\"$ITEM_ID\"" 60 || \
  e2e::verdict_partial "first turn never logged agent_exit_normal (workpad already posted; check terminal reconcile path)"

# §11.8.8 authoritative source: extract the FIRST session's thread_id from
# the orchestrator's structured log. `log_worker_stop`/`Codex session
# started` lines emit `session_id=<thread_id>-<turn_id>` where thread_id
# is a UUIDv7 (see codex/app_server.ex). We pull the session_id for THIS
# issue, take the first 5-segment UUID, and treat that as the canonical
# first thread_id. Sourcing from orch.log (not agent body) closes wave-2
# review NIT 1 (brittle regex) and matches §11.8.8 truthfulness.
SYMPHONY_LOG=$(e2e::current_log)
if [[ -z "$SYMPHONY_LOG" || ! -f "$SYMPHONY_LOG" ]]; then
  e2e::verdict_fail "no symphony.log found via e2e::current_log"
fi

# The session_id format is `<uuidv7-thread>-<uuidv7-turn>` per
# codex/app_server.ex:93. We pin the regex to the exact 5-segment UUIDv7
# shape (8-4-4-4-12 hex) for the FIRST segment and stop matching there.
FIRST_THREAD_ID=$(grep -aE "Codex session started for issue_id=$ITEM_ID " "$SYMPHONY_LOG" \
  | head -1 \
  | grep -oE 'session_id=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
  | head -1 \
  | sed -E 's/^session_id=//' || true)

if [[ -z "$FIRST_THREAD_ID" ]]; then
  e2e::verdict_fail "could not extract first thread_id from orchestrator log (looked for 'Codex session started for issue_id=$ITEM_ID' in $SYMPHONY_LOG). Orchestrator-side regression — §11.8.8 authoritative log missing thread_id."
fi
echo "first_thread_id (orchestrator-authoritative)=$FIRST_THREAD_ID"

# Flip Status → Done to drive terminal reconcile (clean break before Rework).
# Note: archelab/symphony Project #1 has an "Auto-close issue" workflow
# enabled, so setting Status=Done closes the underlying Issue. Flipping
# Status back to Rework alone leaves the Issue CLOSED, and the orchestrator
# correctly refuses to dispatch CLOSED issues (SPEC §11.2.1 terminal-OR
# + §8.2: dispatch requires issue_state == "OPEN"). Reopening the Issue
# alongside the Status flip is required to re-trigger dispatch.
e2e::set_status "$ITEM_ID" "Done"
sleep 6

# Mark the cutoff time for second-dispatch detection. Any `Dispatching`
# line for this issue with a timestamp at or after this cutoff is the
# Rework re-dispatch.
REWORK_CUTOFF_EPOCH=$(date +%s)

# Reopen the issue (Project auto-close closed it on Done flip) and flip
# Status → Rework to trigger a second dispatch.
gh issue reopen "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" >/dev/null
e2e::set_status "$ITEM_ID" "Rework"
echo "flipped to Rework — waiting for second dispatch"

# Wait for the orchestrator to dispatch a SECOND time. We try TWO
# evidence channels because under heavy Codex notification flow the
# `:logger_disk_log_h` async handler can enter drop-mode and silently
# discard info-level messages from symphony.log:
#
#   1) Authoritative: a fresh `Codex session started for issue_id=ITEM_ID`
#      line in symphony.log with a DIFFERENT thread_id from FIRST_THREAD_ID.
#   2) Fallback: a new `rollout-*-<thread_id>.jsonl` file in
#      ~/.codex/sessions newer than FIRST_THREAD_ID's rollout. Codex
#      writes rollouts independently of the orchestrator's Elixir logger.
#
# Either channel proves the second dispatch fired.
SECOND_DISPATCH_DEADLINE=$(( REWORK_CUTOFF_EPOCH + 120 ))
SECOND_THREAD_ID=""
SECOND_ROLL=""

# Resolve the FIRST rollout's epoch mtime as the cutoff for "newer than".
FIRST_ROLL=""
while IFS= read -r -d '' candidate; do
  FIRST_ROLL="$candidate"
  break
done < <(find "$HOME/.codex/sessions" -type f -name "rollout-*-${FIRST_THREAD_ID}.jsonl" -print0 2>/dev/null)
FIRST_ROLL_MTIME=0
if [[ -n "$FIRST_ROLL" ]]; then
  FIRST_ROLL_MTIME=$(stat -f '%m' "$FIRST_ROLL" 2>/dev/null || stat -c '%Y' "$FIRST_ROLL" 2>/dev/null || echo 0)
fi

while (( $(date +%s) < SECOND_DISPATCH_DEADLINE )); do
  # Channel 1: scan symphony.log for a new thread_id on this issue.
  latest_line=$(grep -aE "Codex session started for issue_id=$ITEM_ID " "$SYMPHONY_LOG" | tail -1 || true)
  if [[ -n "$latest_line" ]]; then
    latest_thread=$(printf '%s' "$latest_line" \
      | grep -oE 'session_id=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
      | sed -E 's/^session_id=//' || true)
    if [[ -n "$latest_thread" && "$latest_thread" != "$FIRST_THREAD_ID" ]]; then
      SECOND_THREAD_ID="$latest_thread"
      break
    fi
  fi

  # Channel 2: any rollout newer than the first one signals a second
  # codex session started. Take the newest rollout that isn't FIRST_ROLL.
  while IFS= read -r -d '' candidate; do
    cand_mtime=$(stat -f '%m' "$candidate" 2>/dev/null || stat -c '%Y' "$candidate" 2>/dev/null || echo 0)
    if (( cand_mtime > FIRST_ROLL_MTIME )) && [[ "$candidate" != "$FIRST_ROLL" ]]; then
      SECOND_ROLL="$candidate"
      # Extract thread_id from filename: rollout-<ts>-<thread_id>.jsonl
      SECOND_THREAD_ID=$(basename "$candidate" \
        | sed -E 's/^rollout-[0-9T:-]+-([a-f0-9-]+)\.jsonl$/\1/')
      break
    fi
  done < <(find "$HOME/.codex/sessions" -type f -name "rollout-*.jsonl" -print0 2>/dev/null)

  if [[ -n "$SECOND_THREAD_ID" ]]; then
    break
  fi
  sleep 3
done

if [[ -z "$SECOND_THREAD_ID" ]]; then
  e2e::verdict_partial "second dispatch never observed within 120s after Rework flip (first thread_id=$FIRST_THREAD_ID). No new Codex session in symphony.log AND no new rollout JSONL under \$HOME/.codex/sessions. Orchestrator did not re-dispatch on Rework — could be smoke-mode race, a real Rework regression, or symphony.log handler in overload-drop mode masking the dispatch."
fi
echo "second_thread_id (orchestrator-authoritative)=$SECOND_THREAD_ID"

# Locate the SECOND rollout JSONL by thread id if we haven't already.
if [[ -z "$SECOND_ROLL" ]]; then
  while IFS= read -r -d '' candidate; do
    SECOND_ROLL="$candidate"
    break
  done < <(find "$HOME/.codex/sessions" -type f -name "rollout-*-${SECOND_THREAD_ID}.jsonl" -print0 2>/dev/null)
fi

if [[ -z "$SECOND_ROLL" ]]; then
  e2e::verdict_partial "second rollout JSONL not found for thread_id=$SECOND_THREAD_ID under \$HOME/.codex/sessions. Orchestrator dispatched but Codex rollout absent — likely codex CLI not writing rollouts in this env."
fi
echo "second rollout: $SECOND_ROLL"

# Codex writes the user prompt to the rollout ~5s AFTER session start
# (see first rollout: task_started at t=0, user message at t=5s). When we
# detected the rollout via Channel 2 above, it may contain only
# `task_started` and a stub message — wait until the user prompt is
# actually flushed before asserting on its content. Budget: 30s.
prompt_wait=0
while (( prompt_wait < 30 )); do
  if grep -aq "## Item context" "$SECOND_ROLL"; then
    break
  fi
  sleep 2
  (( prompt_wait+=2 ))
done

# The second dispatch's prompt MUST contain the first session's thread_id
# rendered under `Prior sessions` — see WORKFLOW.workpad.example.md:164:
#   - `{{ s.thread_id }}` attempt={{ s.attempt }} ...
# After Solid render, the literal token is the bare UUIDv7 (no backticks
# inside JSON because the rollout stores the rendered text in
# `payload.message`/`payload.content[].text`). Grep for the first thread
# id appearing in the rollout — that's spec-aligned proof of round-trip.
if grep -aq "Prior sessions" "$SECOND_ROLL" && grep -aq "$FIRST_THREAD_ID" "$SECOND_ROLL"; then
  echo "OK: second prompt contains 'Prior sessions' header AND first thread_id $FIRST_THREAD_ID"
  e2e::verdict_pass
else
  if ! grep -aq "Prior sessions" "$SECOND_ROLL"; then
    e2e::verdict_fail "second rollout ($SECOND_ROLL) missing 'Prior sessions' header — workpad prompt section not rendered on Rework re-dispatch."
  else
    e2e::verdict_fail "second rollout ($SECOND_ROLL) has 'Prior sessions' but first thread_id ($FIRST_THREAD_ID) absent — orchestrator did not pass prior_sessions[0] to prompt_builder."
  fi
fi
