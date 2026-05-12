#!/usr/bin/env bash
# Shared helpers for Symphony e2e smoke tests.
#
# Usage: source lib.sh
#
# Required env (set/exported by run.sh before sourcing this file):
#   SYMPHONY_E2E_PROJECT_OWNER (e.g. archelab)
#   SYMPHONY_E2E_PROJECT_NUMBER (e.g. 1)
#   SYMPHONY_E2E_REPO (e.g. symphony)
#
# After e2e::resolve_project_ids is called, the following are exported:
#   E2E_PROJECT_ID
#   E2E_STATUS_FIELD_ID
#   E2E_REPO_NODE_ID
#   E2E_STATUS_OPTIONS — newline-delimited "<name>\t<id>"
#
# Set by run.sh:
#   E2E_LOG_DIR (default /tmp/symphony-smoke-log)
#   E2E_WORKSPACE_ROOT (default /tmp/symphony-smoke-workspaces)
#   E2E_ELIXIR_DIR (absolute path to elixir/ in the repo)
#   E2E_REPORT_PATH (where to append PASS/FAIL evidence)

set -u

e2e::log() {
  printf '[e2e] %s\n' "$*" >&2
}

e2e::die() {
  printf '[e2e][FATAL] %s\n' "$*" >&2
  exit 1
}

# Resolves project + Status field ids from owner/number. Sets E2E_* exports.
e2e::resolve_project_ids() {
  local owner="${SYMPHONY_E2E_PROJECT_OWNER}"
  local number="${SYMPHONY_E2E_PROJECT_NUMBER}"
  local repo="${SYMPHONY_E2E_REPO}"

  local resp
  resp=$(gh api graphql -f query="
    query {
      organization(login: \"$owner\") {
        projectV2(number: $number) {
          id
          field(name: \"Status\") {
            ... on ProjectV2SingleSelectField {
              id
              options { id name }
            }
          }
        }
      }
      repository(owner: \"$owner\", name: \"$repo\") { id }
    }
  ") || e2e::die "Failed to resolve project ids"

  export E2E_PROJECT_ID
  E2E_PROJECT_ID=$(jq -r '.data.organization.projectV2.id' <<<"$resp")
  [[ "$E2E_PROJECT_ID" != "null" ]] || e2e::die "Project not found: $owner #$number"

  export E2E_STATUS_FIELD_ID
  E2E_STATUS_FIELD_ID=$(jq -r '.data.organization.projectV2.field.id' <<<"$resp")
  [[ "$E2E_STATUS_FIELD_ID" != "null" ]] || e2e::die "Status field not found"

  export E2E_REPO_NODE_ID
  E2E_REPO_NODE_ID=$(jq -r '.data.repository.id' <<<"$resp")

  # Cache options as newline-delimited "name<TAB>id" pairs
  export E2E_STATUS_OPTIONS
  E2E_STATUS_OPTIONS=$(jq -r '.data.organization.projectV2.field.options[] | "\(.name)\t\(.id)"' <<<"$resp")

  e2e::log "Project: $E2E_PROJECT_ID  StatusField: $E2E_STATUS_FIELD_ID  Repo: $E2E_REPO_NODE_ID"
}

# Returns the option id for a given Status option name (case-insensitive).
e2e::status_option_id() {
  local name="$1"
  local id
  id=$(awk -v n="$name" -F'\t' 'BEGIN{IGNORECASE=1} tolower($1)==tolower(n){print $2}' <<<"$E2E_STATUS_OPTIONS")
  [[ -n "$id" ]] || e2e::die "Unknown Status option: $name"
  printf '%s' "$id"
}

# Create a real GitHub issue. Echoes "<issue_num>\t<issue_node_id>".
e2e::create_test_issue() {
  local title="$1"
  local body="${2:-Smoke test issue. DO NOT act on this issue.}"

  local response=""
  local output
  local retry_pattern='submitted too quickly|secondary rate|temporarily blocked from content creation|abuse|try again later'
  local exit_code

  for _attempt in {1..12}; do
    set +e
    output=$(gh api "repos/$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO/issues" \
      -X POST \
      -f title="$title" \
      -f body="$body" 2>&1)
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]] && jq -e '.number and .node_id' <<<"$output" >/dev/null 2>&1; then
      response="$output"
      break
    fi

    if [[ "$output" =~ $retry_pattern ]] || [[ -z "$output" ]]; then
      sleep 10
      continue
    fi

    e2e::die "gh issue create failed: $output"
  done

  [[ -n "$response" ]] || e2e::die "gh issue REST create returned no issue after retries"

  local num
  num=$(jq -r '.number' <<<"$response")
  local node_id
  node_id=$(jq -r '.node_id' <<<"$response")
  printf '%s\t%s\n' "$num" "$node_id"
}

# Echoes the database (numeric) id for an issue number.
e2e::issue_database_id() {
  local num="$1"
  gh api graphql -f query="
    query { repository(owner:\"$SYMPHONY_E2E_PROJECT_OWNER\", name:\"$SYMPHONY_E2E_REPO\") {
      issue(number: $num) { databaseId }
    } }
  " --jq '.data.repository.issue.databaseId'
}

# Adds an existing issue/PR/draft to the project. Echoes the project item id.
e2e::add_to_project() {
  local content_id="$1"
  gh api graphql -f query="
    mutation {
      addProjectV2ItemById(input:{ projectId:\"$E2E_PROJECT_ID\", contentId:\"$content_id\" }) {
        item { id }
      }
    }
  " --jq '.data.addProjectV2ItemById.item.id'
}

# Sets Status on a project item by option name.
e2e::set_status() {
  local item_id="$1"
  local option_name="$2"
  local option_id
  option_id=$(e2e::status_option_id "$option_name")
  gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input:{
        projectId:\"$E2E_PROJECT_ID\",
        itemId:\"$item_id\",
        fieldId:\"$E2E_STATUS_FIELD_ID\",
        value:{ singleSelectOptionId:\"$option_id\" }
      }) { projectV2Item { id } }
    }
  " --jq '.data.updateProjectV2ItemFieldValue.projectV2Item.id' >/dev/null
}

# Clears Status on a project item.
e2e::clear_status() {
  local item_id="$1"
  gh api graphql -f query="
    mutation {
      clearProjectV2ItemFieldValue(input:{
        projectId:\"$E2E_PROJECT_ID\",
        itemId:\"$item_id\",
        fieldId:\"$E2E_STATUS_FIELD_ID\"
      }) { projectV2Item { id } }
    }
  " --jq '.data.clearProjectV2ItemFieldValue.projectV2Item.id' >/dev/null
}

# Deletes a project item.
e2e::delete_project_item() {
  local item_id="$1"
  gh api graphql -f query="
    mutation {
      deleteProjectV2Item(input:{ projectId:\"$E2E_PROJECT_ID\", itemId:\"$item_id\" }) { deletedItemId }
    }
  " --jq '.data.deleteProjectV2Item.deletedItemId' >/dev/null 2>&1 || true
}

# Links a child issue as a sub-issue of parent via REST.
# Echoes nothing on success, non-zero on failure (e.g. older repos without sub-issue support).
e2e::link_sub_issue() {
  local parent_num="$1"
  local child_db_id="$2"
  local resp
  resp=$(curl -sS -X POST \
    -H "Authorization: Bearer $(gh auth token)" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO/issues/$parent_num/sub_issues" \
    -d "{\"sub_issue_id\": $child_db_id}" 2>&1) || return 1
  # If response has "url" we're fine; "message" indicates an error
  if jq -e '.message' >/dev/null 2>&1 <<<"$resp"; then
    echo "$resp" >&2
    return 1
  fi
}

# Start the orchestrator. Writes pid to E2E_ORCH_PID file.
# Args: $1 = run.log path
e2e::start_orchestrator() {
  local run_log="$1"
  : >"$run_log"
  (
    cd "$E2E_ELIXIR_DIR"
    GITHUB_TOKEN=$(gh auth token) nohup mise exec -- mix run --no-halt >"$run_log" 2>&1 &
    disown
    echo $! >"$E2E_LOG_DIR/orch.pid"
  )
  e2e::log "Started orchestrator (pid in $E2E_LOG_DIR/orch.pid). Waiting for boot..."
  e2e::wait_for_file_content "$run_log" 'Project:' 30 || e2e::die "Orchestrator failed to boot within 30s"
}

# Stop the orchestrator.
e2e::stop_orchestrator() {
  pkill -9 -f 'beam.smp.*mix run' 2>/dev/null || true
  sleep 1
  rm -f "$E2E_LOG_DIR/orch.pid"
}

# Wait for a regex to appear in a file. Args: file regex timeout_s
e2e::wait_for_file_content() {
  local file="$1"
  local regex="$2"
  local timeout_s="${3:-30}"
  local elapsed=0
  while (( elapsed < timeout_s )); do
    [[ -f "$file" ]] && grep -aE "$regex" "$file" >/dev/null 2>&1 && return 0
    sleep 1
    (( elapsed++ ))
  done
  return 1
}

# Resolve the current orchestrator log file.
e2e::current_log() {
  /bin/ls -t "$E2E_ELIXIR_DIR/log/"symphony.log.* 2>/dev/null \
    | grep -vE '\.idx$|\.siz$' \
    | head -1
}

# Wait for a regex to appear in the orchestrator log. Args: regex timeout_s
e2e::wait_for_log_line() {
  local regex="$1"
  local timeout_s="${2:-30}"
  local elapsed=0
  local log
  while (( elapsed < timeout_s )); do
    log=$(e2e::current_log)
    if [[ -n "$log" ]] && grep -aE "$regex" "$log" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    (( elapsed++ ))
  done
  return 1
}

# Assert NO matching log line appears within DURATION_S. Args: regex duration_s
e2e::assert_no_log_line() {
  local regex="$1"
  local duration_s="${2:-30}"
  sleep "$duration_s"
  local log
  log=$(e2e::current_log)
  if [[ -n "$log" ]] && grep -aE "$regex" "$log" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Clean up all smoke-test items in the project (items whose title starts with `[smoke]`).
e2e::cleanup_smoke_items() {
  local items_json
  items_json=$(gh api graphql -f query="
    query { node(id:\"$E2E_PROJECT_ID\") { ... on ProjectV2 {
      items(first:100) { nodes {
        id
        content { __typename ... on Issue { number title state } }
      } }
    } } }
  " 2>/dev/null) || return 0

  local item_ids
  item_ids=$(jq -r '.data.node.items.nodes[]
    | select(.content.title | startswith("[smoke]"))
    | .id' <<<"$items_json")

  local issue_nums
  issue_nums=$(jq -r '.data.node.items.nodes[]
    | select(.content.title | startswith("[smoke]"))
    | select(.content.__typename == "Issue")
    | select(.content.state == "OPEN")
    | .content.number' <<<"$items_json")

  # Close open issues first (silently — they may auto-close on item delete)
  while IFS= read -r num; do
    [[ -n "$num" ]] && gh issue close "$num" -R "$SYMPHONY_E2E_PROJECT_OWNER/$SYMPHONY_E2E_REPO" >/dev/null 2>&1 || true
  done <<<"$issue_nums"

  while IFS= read -r item; do
    [[ -n "$item" ]] && e2e::delete_project_item "$item" || true
  done <<<"$item_ids"

  # When `item_ids` is empty, the final `[[ -n "$item" ]] && ...` short-circuits
  # to rc=1 and trips `set -e` at the call site. Guard the function's exit code.
  return 0
}

# Swap WORKFLOW.md to the smoke version (backing up original).
e2e::swap_workflow_in() {
  local workflow="$E2E_ELIXIR_DIR/WORKFLOW.md"
  local smoke="$E2E_SCRIPT_DIR/workflow.smoke.md"
  if [[ ! -f "$workflow.e2e_orig" ]]; then
    cp "$workflow" "$workflow.e2e_orig"
  fi
  cp "$smoke" "$workflow"
}

# Restore WORKFLOW.md from backup.
e2e::swap_workflow_out() {
  local workflow="$E2E_ELIXIR_DIR/WORKFLOW.md"
  if [[ -f "$workflow.e2e_orig" ]]; then
    mv "$workflow.e2e_orig" "$workflow"
  fi
}

# Verdict helpers: each test case calls one of these as its LAST line.
e2e::verdict_pass()  { echo "PASS"; exit 0; }
e2e::verdict_fail()  { echo "FAIL: $*"; exit 1; }
e2e::verdict_skip()  { echo "SKIP: $*"; exit 2; }
e2e::verdict_partial() { echo "PARTIAL: $*"; exit 3; }
