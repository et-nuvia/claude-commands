#!/usr/bin/env bats
# Tests for asana.sh — the Asana REST shim that replaced the asana-mcp container.
# curl is mocked via PATH so no network calls are made.

SCRIPT="${BATS_TEST_DIRNAME}/../asana.sh"

setup() {
  TMP_DIR="$(mktemp -d)"
  export HOME="$TMP_DIR"            # isolate from real ~/.asana-token / ~/.asana-workspace
  export ASANA_ACCESS_TOKEN="test-token"
  export ASANA_WORKSPACE_GID="999000"
  export CURL_LOG="$TMP_DIR/curl.log"
  export MOCK_DIR="$TMP_DIR/bin"
  mkdir -p "$MOCK_DIR"

  # Mock curl: logs args, returns canned JSON + HTTP code based on URL/method.
  # Mirrors the real api() contract: body then \n<http_code> (-w '\n%{http_code}').
  cat > "$MOCK_DIR/curl" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$CURL_LOG"
url=""
method="GET"
prev=""
for arg in "$@"; do
  [[ "$prev" == "-X" ]] && method="$arg"
  [[ "$arg" == https://* ]] && url="$arg"
  prev="$arg"
done
respond() { printf '%s\n200' "$1"; }
case "$url" in
  *"/users/me"*)
    respond '{"data":{"gid":"42","name":"Test User"}}' ;;
  *"/workspaces"*"/tasks/search"*)
    respond '{"data":[{"gid":"801","name":"found task"}]}' ;;
  *"/workspaces"*"/custom_fields"*)
    respond '{"data":[{"gid":"71","name":"Status Dev","resource_subtype":"enum"},{"gid":"74","name":"Score","resource_subtype":"enum"},{"gid":"75","name":"Sprint","resource_subtype":"text"}]}' ;;
  *"/workspaces"*)
    respond '{"data":[{"gid":"999000","name":"Test Workspace"}]}' ;;
  *"/projects?workspace="*)
    respond '{"data":[{"gid":"111","name":"Engineering"},{"gid":"222","name":"Priority Support"}]}' ;;
  *"/projects/111/addCustomFieldSetting"*)
    respond '{"data":{"gid":"9001","custom_field":{"gid":"74","name":"Score"}}}' ;;
  *"/projects/111/removeCustomFieldSetting"*)
    respond '{"data":{}}' ;;
  *"/projects/111/sections/insert"*)
    respond '{"data":{}}' ;;
  *"/projects/111/sections"*)
    case "$method" in
      POST) respond '{"data":{"gid":"33","name":"Backlog"}}' ;;
      *)    respond '{"data":[{"gid":"31","name":"To Do"},{"gid":"32","name":"In Progress"}]}' ;;
    esac ;;
  # Section 32 is empty (safe to delete); section 31 still holds a task.
  *"/sections/32/tasks"*)
    respond '{"data":[]}' ;;
  *"/sections/31/tasks"*)
    respond '{"data":[{"gid":"601","name":"task one","completed":false}]}' ;;
  *"/sections/32"*)
    case "$method" in
      DELETE) respond '{"data":{}}' ;;
      *)      respond '{"data":{"gid":"32","name":"In Progress"}}' ;;
    esac ;;
  *"/projects/111/custom_field_settings"*)
    respond '{"data":[{"custom_field":{"gid":"71","name":"Status Dev","resource_subtype":"enum","enum_options":[{"gid":"711","name":"In progress"},{"gid":"712","name":"Done"}]}},{"custom_field":{"gid":"72","name":"Priority ","resource_subtype":"enum","enum_options":[{"gid":"721","name":"Medium"}]}},{"custom_field":{"gid":"73","name":"Requesting User","resource_subtype":"text"}},{"custom_field":{"gid":"74","name":"Score","resource_subtype":"enum","enum_options":[{"gid":"741","name":"1"},{"gid":"745","name":"5"}]}}]}' ;;
  *"/tasks/500/stories"*)
    respond '{"data":{"gid":"900","type":"comment","text":"hi"}}' ;;
  *"/tasks/500"*)
    case "$method" in
      PUT) respond '{"data":{"gid":"500","completed":true}}' ;;
      *)   respond '{"data":{"gid":"500","name":"a task","memberships":[{"project":{"gid":"111"}}],"projects":[{"gid":"111"}]}}' ;;
    esac ;;
  *"/tasks/404"*)
    printf '%s\n404' '{"errors":[{"message":"task: Not the GID of a task"}]}' ;;
  *"/tasks?opt_fields="*)
    respond '{"data":{"gid":"700","name":"created","permalink_url":"https://app.asana.com/x/700"}}' ;;
  *"/tasks?"*)
    respond '{"data":[{"gid":"601","name":"task one"}]}' ;;
  *"/sections/31/addTask"*)
    respond '{"data":{}}' ;;
  *)
    printf '%s\n500' '{"errors":[{"message":"unmocked URL: '"$url"'"}]}' ;;
esac
MOCK
  chmod +x "$MOCK_DIR/curl"
  export PATH="$MOCK_DIR:$PATH"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "asana get-current-user returns unwrapped .data" {
  run "$SCRIPT" get-current-user
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.gid')" = "42" ]
}

@test "asana get-task hits /tasks/<gid> and unwraps .data" {
  run "$SCRIPT" get-task 500
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.name')" = "a task" ]
  grep -q "/tasks/500" "$CURL_LOG"
}

@test "asana list-tasks with --project uses project= and omits workspace" {
  run "$SCRIPT" list-tasks --project 111
  [ "$status" -eq 0 ]
  grep -q "tasks?project=111" "$CURL_LOG"
  ! grep -q "tasks?.*workspace=" "$CURL_LOG"
}

@test "asana list-tasks defaults to workspace from env + assignee=me" {
  run "$SCRIPT" list-tasks
  [ "$status" -eq 0 ]
  grep -q "tasks?workspace=999000&assignee=me" "$CURL_LOG"
}

@test "asana list-tasks resolves project name to GID via fuzzy match" {
  run "$SCRIPT" list-tasks --project "engineering"
  [ "$status" -eq 0 ]
  grep -q "tasks?project=111" "$CURL_LOG"
}

@test "asana create-task sends name/notes/projects and requests permalink_url" {
  run "$SCRIPT" create-task --name "My Task" --notes "details" --project 111
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.permalink_url')" = "https://app.asana.com/x/700" ]
  grep -q "opt_fields=.*permalink_url" "$CURL_LOG"
  grep -q '"name":"My Task"' "$CURL_LOG" || grep -q '"name": *"My Task"' "$CURL_LOG"
}

@test "asana create-task with --section adds memberships for first project" {
  run "$SCRIPT" create-task --name "T" --project 111 --section "To Do"
  [ "$status" -eq 0 ]
  grep -q '"memberships"' "$CURL_LOG"
  grep -q '"section": *"31"' "$CURL_LOG"
}

@test "asana create-task --section without --project fails" {
  run "$SCRIPT" create-task --name "T" --section "To Do"
  [ "$status" -ne 0 ]
}

@test "asana update-task --completed false sends boolean in body" {
  run "$SCRIPT" update-task 500 --completed false
  [ "$status" -eq 0 ]
  grep -q '"completed": *false' "$CURL_LOG"
}

@test "asana update-task with no fields fails" {
  run "$SCRIPT" update-task 500
  [ "$status" -ne 0 ]
}

@test "asana complete-task sends completed:true PUT" {
  run "$SCRIPT" complete-task 500
  [ "$status" -eq 0 ]
  grep -q '"completed":true' "$CURL_LOG"
}

@test "asana add-comment posts text to stories endpoint" {
  run "$SCRIPT" add-comment 500 --text "hello world"
  [ "$status" -eq 0 ]
  grep -q "/tasks/500/stories" "$CURL_LOG"
  grep -q '"text": *"hello world"' "$CURL_LOG"
}

@test "asana update-custom-field resolves enum option name to GID" {
  # field "Status" fuzzy-matches "Status Dev"; value "In progress" -> option 711
  run "$SCRIPT" update-custom-field 500 --field "Status" --value "In progress" --project 111
  [ "$status" -eq 0 ]
  grep -q '"71": *"711"' "$CURL_LOG"
}

@test "asana update-custom-field fuzzy-matches field name with trailing space" {
  run "$SCRIPT" update-custom-field 500 --field "Priority" --value "Medium" --project 111
  [ "$status" -eq 0 ]
  grep -q '"72": *"721"' "$CURL_LOG"
}

@test "asana update-custom-field infers project from task memberships" {
  # no --project: should GET /tasks/500 first, find project 111, then resolve field
  run "$SCRIPT" update-custom-field 500 --field "Status" --value "Done"
  [ "$status" -eq 0 ]
  grep -q '"71": *"712"' "$CURL_LOG"
}

@test "asana update-custom-field unknown enum value fails" {
  run "$SCRIPT" update-custom-field 500 --field "Status" --value "NopeNotReal" --project 111
  [ "$status" -ne 0 ]
}

# The Score field's option names are fibonacci numbers, so an all-digits value
# is an option NAME, not a GID. Treating it as a GID sent "5" straight through
# as the enum value and Asana rejected it ("Unknown object: 5").
@test "asana update-custom-field resolves a numeric enum option name to its GID" {
  run "$SCRIPT" update-custom-field 500 --field "Score" --value "5" --project 111
  [ "$status" -eq 0 ]
  grep -q '"74": *"745"' "$CURL_LOG"
}

@test "asana update-custom-field passes a real enum option GID through verbatim" {
  run "$SCRIPT" update-custom-field 500 --field "Score" --value "741" --project 111
  [ "$status" -eq 0 ]
  grep -q '"74": *"741"' "$CURL_LOG"
}

@test "asana update-custom-field rejects a numeric value that is not an option" {
  run "$SCRIPT" update-custom-field 500 --field "Score" --value "99" --project 111
  [ "$status" -ne 0 ]
}

# --- project structure: sections and custom-field attachment -----------------

@test "asana create-section posts a new section" {
  run "$SCRIPT" create-section --project 111 --name "Backlog"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "created" ]
  [ "$(echo "$output" | jq -r '.gid')" = "33" ]
}

# Creating a duplicate name would make every later name lookup ambiguous.
@test "asana create-section is idempotent by name" {
  run "$SCRIPT" create-section --project 111 --name "To Do"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "exists" ]
  [ "$(echo "$output" | jq -r '.gid')" = "31" ]
  ! grep -q "POST.*projects/111/sections" "$CURL_LOG"
}

@test "asana delete-section removes an empty section" {
  run "$SCRIPT" delete-section --section 32
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "deleted" ]
}

# Asana refuses to delete a non-empty section; say so with the count instead of
# surfacing a bare 400.
@test "asana delete-section refuses a non-empty section" {
  run "$SCRIPT" delete-section --section 31
  [ "$status" -ne 0 ]
  [[ "$output" == *"still holds"* ]]
}

@test "asana list-section-tasks filters by completion" {
  run "$SCRIPT" list-section-tasks --section 31 --completed false
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "1" ]
  run "$SCRIPT" list-section-tasks --section 31 --completed true
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "0" ]
}

@test "asana list-workspace-fields filters by name" {
  run "$SCRIPT" list-workspace-fields --name score
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].gid')" = "74" ]
}

# "Sprint" exists in the workspace but is not attached to project 111.
@test "asana add-project-field resolves a field by name and attaches it" {
  run "$SCRIPT" add-project-field --project 111 --field "Sprint"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "added" ]
  grep -q "addCustomFieldSetting" "$CURL_LOG"
}

# Already-attached is reported, not re-POSTed, so the command is safe to re-run
# against a partly-conformant project.
@test "asana add-project-field is idempotent for an attached field" {
  run "$SCRIPT" add-project-field --project 111 --field "Status Dev"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "exists" ]
  ! grep -q "addCustomFieldSetting" "$CURL_LOG"
}

@test "asana remove-project-field detaches a field" {
  run "$SCRIPT" remove-project-field --project 111 --field "Score"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "removed" ]
  grep -q "removeCustomFieldSetting" "$CURL_LOG"
}

@test "asana move-task-to-section resolves section and posts addTask" {
  run "$SCRIPT" move-task-to-section 500 --section "To Do" --project 111
  [ "$status" -eq 0 ]
  grep -q "/sections/31/addTask" "$CURL_LOG"
}

@test "asana search-tasks url-encodes text and uses workspace search endpoint" {
  run "$SCRIPT" search-tasks --text "hello world"
  [ "$status" -eq 0 ]
  grep -q "/workspaces/999000/tasks/search?text=hello%20world" "$CURL_LOG"
}

@test "asana HTTP error returns JSON error on stderr and non-zero exit" {
  run --separate-stderr "$SCRIPT" get-task 404
  [ "$status" -eq 1 ]
  [ "$(echo "$stderr" | jq -r '.http_status')" = "404" ]
}

@test "asana fails cleanly with no token" {
  unset ASANA_ACCESS_TOKEN
  run "$SCRIPT" get-current-user
  [ "$status" -ne 0 ]
  [[ "$output" == *"token"* ]] || [[ "$stderr" == *"token"* ]]
}

@test "asana unknown command fails with error" {
  run "$SCRIPT" frobnicate
  [ "$status" -ne 0 ]
}
