#!/usr/bin/env bash
# E2E-10: Agent Workpad Protocol round-trip (SPEC §11.8).
#
# 1. Swap WORKFLOW.md for a workpad-enabled variant (built per-run from
#    workflow.smoke.md + WORKFLOW.workpad.example.md fragments).
# 2. Create a fresh issue with AGENT PRIORITY INSTRUCTIONS to post a v1
#    workpad comment containing the orchestrator-supplied {{ thread_id }},
#    {{ model }}, etc.
# 3. Set Status → Agent Ready. Wait for orchestrator dispatch + workpad
#    marker on the issue.
# 4. Flip Status → Done (terminal reconcile), then Rework (re-dispatch).
# 5. Read the latest Codex rollout JSONL and confirm the second prompt
#    rendered with the first session's thread_id under prior_sessions[0].
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
# workpad block + a stronger model. We write directly into the canonical
# WORKFLOW.md slot (run.sh has already swapped the smoke variant in) and
# restore on EXIT.
WORKFLOW="$E2E_ELIXIR_DIR/WORKFLOW.md"
BACKUP="$WORKFLOW.e2e10_bak"
cp "$WORKFLOW" "$BACKUP"

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

cleanup_e2e10() {
  mv "$BACKUP" "$WORKFLOW"
}
trap cleanup_e2e10 EXIT

e2e::start_orchestrator "$E2E_LOG_DIR/run.log"

# Create issue with placeholder body; we edit the body to include the
# just-created node id for the AGENT PRIORITY INSTRUCTION.
read -r ISSUE_NUM ISSUE_NODE_ID < <(e2e::create_test_issue "[smoke] E2E-10 workpad roundtrip" \
  "placeholder — will edit body below")

# The workpad-enabled prompt template already instructs the agent to find
# or create a workpad comment via `addComment` with the v1 marker. The
# body below adds an explicit priority instruction so the smoke-mode
# model (which usually ignores templates) does the right thing.
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
elapsed=0
first_thread_id=""
while (( elapsed < 150 )); do
  comments_json=$(gh issue view "$ISSUE_NUM" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" --json comments 2>/dev/null || echo '{}')
  marker_body=$(jq -r '.comments[]?.body | select(. != null) | select(contains("<!-- symphony-workpad:v1 -->"))' <<<"$comments_json" | head -1)
  if [[ -n "$marker_body" ]]; then
    # Try to extract the first thread_id the agent wrote into the comment.
    # The exact shape is agent-controlled, so we accept any non-trivial
    # alphanumeric/dash token after the literal "thread_id" word.
    first_thread_id=$(printf '%s' "$marker_body" | grep -ioE 'thread[_-]?id[^a-z0-9_-]+[a-z0-9_-]{6,}' | head -1 | sed -E 's/.*[^a-z0-9_-]([a-z0-9_-]{6,})$/\1/' || true)
    break
  fi
  sleep 5
  (( elapsed+=5 ))
done

if [[ -z "$marker_body" ]]; then
  e2e::verdict_partial "no v1 workpad marker on issue within 150s — agent did not post workpad. Likely smoke-mode model ignored instructions."
fi

echo "first_workpad_body=$(printf '%s' "$marker_body" | head -c 200)"
echo "first_thread_id_guess=$first_thread_id"

# Wait for first turn to exit cleanly.
e2e::wait_for_log_line "worker stop reason=:agent_exit_normal issue_id=\"$ITEM_ID\"" 60 || \
  e2e::verdict_partial "first turn never logged agent_exit_normal (workpad already posted; check terminal reconcile path)"

# Flip Status → Done to drive terminal reconcile (clean break before Rework).
e2e::set_status "$ITEM_ID" "Done"
sleep 6

# Flip Status → Rework to trigger a second dispatch.
e2e::set_status "$ITEM_ID" "Rework"
echo "flipped to Rework — waiting for second dispatch"

# Second dispatch — should re-render the prompt with prior_sessions[0].
# `wait_for_log_line` matches any new occurrence; the orchestrator logs a
# new "Dispatching issue to agent" line per dispatch.
sleep 15

# Read the latest Codex rollout JSONL and confirm the first session's
# thread_id appears in the second prompt's prior_sessions context.
ROLL=$(/bin/ls -t "$HOME/.codex/sessions/"*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
if [[ -z "$ROLL" ]]; then
  e2e::verdict_fail "no rollout file under ~/.codex/sessions"
fi

echo "latest rollout: $ROLL"

# The workpad-enabled template emits a "Prior sessions" header + a bullet
# per record under `{% for s in prior_sessions %}`. The second dispatch's
# rollout must contain at least one such bullet referencing a thread_id.
if grep -aq "Prior sessions" "$ROLL" && grep -aqE "thread_id=" "$ROLL"; then
  if [[ -n "$first_thread_id" ]] && grep -aq "$first_thread_id" "$ROLL"; then
    echo "OK: second prompt contains prior_sessions section + first thread_id $first_thread_id"
    e2e::verdict_pass
  else
    e2e::verdict_partial "Prior sessions header rendered but first thread_id ($first_thread_id) not located in $ROLL"
  fi
else
  e2e::verdict_fail "Prior sessions section not in latest rollout ($ROLL)"
fi
