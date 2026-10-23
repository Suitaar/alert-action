#!/usr/bin/env bash
# The test of src/notify.sh and src/base-url.sh, against a local stand-in of the Opsgenie API
# (test/stand-in.py). Needs bash, python3, jq and curl, and a free port 18891.
#
#   test/notify-test.sh
#
# It ends with "N of M passed" and exits 0 only when all checks pass.
set -uo pipefail
export LC_ALL=C

here="$(cd "$(dirname "$0")" && pwd)"
notify="$here/../src/notify.sh"
base_url="$here/../src/base-url.sh"
work="$(mktemp -d)"
port=18891
key="test-key-0123456789"
cleanup() { [ -n "${server:-}" ] && kill "$server" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
passed=0
total=0
check() {
	total=$((total + 1))
	if [ "$2" = 0 ]; then passed=$((passed + 1)); echo "PASS $1"; else echo "FAIL $1"; fi
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
has() { grep -qF -- "$1" "$work/out"; }
lacks() { ! grep -qF -- "$1" "$work/out"; }
last() { tail -n 1 "$work/requests"; }
field() { last | jq -r "$1"; }
output() { sed -n "s/^$1=//p" "$work/github-output" | tail -n 1; }

echo ok >"$work/mode"
: >"$work/requests"
python3 "$here/stand-in.py" "$port" "$work" & server=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done

# run [VAR=value …]: notify.sh with the stand-in and the test key; output in $work/out.
run() {
	: >"$work/github-output"
	env -i PATH="$PATH" HOME="$HOME" NOTIFY_BASE_URL="http://127.0.0.1:$port" NOTIFY_API_KEY="$key" \
		GITHUB_OUTPUT="$work/github-output" "$@" "$notify" >"$work/out" 2>&1
}

echo "== create"
run NOTIFY_ACTION=create NOTIFY_MESSAGE='Build "main" * failed' NOTIFY_ALIAS="ci-main" \
	NOTIFY_DESCRIPTION=$'Line one\nLine two with * and $HOME' NOTIFY_PRIORITY=P2 NOTIFY_TAGS="ci, main" \
	NOTIFY_DETAILS='{"run": "42"}' NOTIFY_USER="github" NOTIFY_SOURCE="GitHub Actions" NOTIFY_NOTE="first"; code=$?
check "exit 0" "$(yes_if [ "$code" = 0 ])"
check "POST /v2/alerts with the GenieKey header" "$(yes_if [ "$(field '.method + " " + .path + " " + .auth')" = "POST /v2/alerts GenieKey $key" ])"
check "the message and the description are kept as written" \
	"$(yes_if [ "$(field '.body | fromjson | .message + "|" + .description')" = $'Build "main" * failed|Line one\nLine two with * and $HOME' ])"
check "alias, priority, tags, details, user, source, note" \
	"$(yes_if [ "$(field '.body | fromjson | [.alias, .priority, (.tags | join(",")), .details.run, .user, .source, .note] | join("|")')" = "ci-main|P2|ci,main|42|github|GitHub Actions|first" ])"
check "outputs status and request-id" "$(yes_if [ "$(output status) $(output request-id)" = "202 req-1" ])"
check "says what happened" "$(yes_if has "Suitaar alert: create answered 202 (request req-1).")"
check "never prints the key" "$(yes_if lacks "$key")"

echo "== create with only a message: no empty fields"
run NOTIFY_ACTION=create NOTIFY_MESSAGE="Deploy failed"
check "the body has only the message" "$(yes_if [ "$(field '.body | fromjson | keys | join(",")')" = "message" ])"

echo "== close, acknowledge, note"
run NOTIFY_ACTION=close NOTIFY_ALIAS="ci main/1" NOTIFY_USER="github" NOTIFY_NOTE="fixed"
check "close: the alias is URL-encoded, identifierType=alias" \
	"$(yes_if [ "$(field '.method + " " + .path + "?" + .query')" = "POST /v2/alerts/ci%20main%2F1/close?identifierType=alias" ])"
check "close: user and note" "$(yes_if [ "$(field '.body | fromjson | .user + "|" + .note')" = "github|fixed" ])"
run NOTIFY_ACTION=acknowledge NOTIFY_ALIAS="ci-main" NOTIFY_SOURCE="GitHub Actions"
check "acknowledge" "$(yes_if [ "$(field '.path + " " + (.body | fromjson | .source)')" = "/v2/alerts/ci-main/acknowledge GitHub Actions" ])"
run NOTIFY_ACTION=note NOTIFY_ALIAS="ci-main" NOTIFY_NOTE="Rerun started"
check "note" "$(yes_if [ "$(field '.path + " " + (.body | fromjson | .note)')" = "/v2/alerts/ci-main/notes Rerun started" ])"

echo "== heartbeat"
run NOTIFY_ACTION=heartbeat NOTIFY_HEARTBEAT="nightly backup"; code=$?
check "GET /v2/heartbeats/<name>/ping, the name URL-encoded" \
	"$(yes_if [ "$(field '.method + " " + .path')" = "GET /v2/heartbeats/nightly%20backup/ping" ])"
check "exit 0 and status 202" "$(yes_if [ "$code" = 0 ] && [ "$(output status)" = 202 ])"

echo "== input errors: a warning and no request; with fail-on-error, the step fails"
: >"$work/requests"
for case in "create|NOTIFY_MESSAGE=|message is required" "close|NOTIFY_ALIAS=|alias is required" \
	"note|NOTIFY_ALIAS=x|note is required" "heartbeat|NOTIFY_HEARTBEAT=|heartbeat is required" \
	"create|NOTIFY_PRIORITY=P9|priority must be P1, P2, P3, P4 or P5" "create|NOTIFY_DETAILS=[1]|details must be a JSON object" \
	"page|NOTIFY_ALIAS=x|action must be create, close, acknowledge, note or heartbeat"; do
	IFS='|' read -r action setting reason <<<"$case"
	run NOTIFY_ACTION="$action" NOTIFY_MESSAGE="m" "$setting"; code=$?
	check "$action, $setting: a warning, exit 0" "$(yes_if [ "$code" = 0 ] && has "::warning::Suitaar alert: $reason")"
	run NOTIFY_ACTION="$action" NOTIFY_MESSAGE="m" "$setting" NOTIFY_FAIL_ON_ERROR=true; code=$?
	check "$action, $setting: with fail-on-error, an error and exit 1" "$(yes_if [ "$code" = 1 ] && has "::error::Suitaar alert: $reason")"
done
check "no request was sent" "$(yes_if [ ! -s "$work/requests" ])"

echo "== the API refuses or fails"
echo 401 >"$work/mode"
run NOTIFY_ACTION=create NOTIFY_MESSAGE="m"; code=$?
check "401: a warning with the API's message, exit 0, status 401" \
	"$(yes_if [ "$code" = 0 ] && has "::warning::Suitaar alert: create answered 401: Key format is not valid! (request req-401)" && [ "$(output status)" = 401 ])"
run NOTIFY_ACTION=create NOTIFY_MESSAGE="m" NOTIFY_FAIL_ON_ERROR=true; code=$?
check "401 with fail-on-error: exit 1" "$(yes_if [ "$code" = 1 ])"
echo 500 >"$work/mode"
run NOTIFY_ACTION=create NOTIFY_MESSAGE="m"; code=$?
check "500 without JSON: a warning without the HTML body" "$(yes_if [ "$code" = 0 ] && has "::warning::Suitaar alert: create answered 500." && lacks "<html>")"
echo ok >"$work/mode"
env -i PATH="$PATH" NOTIFY_BASE_URL="http://127.0.0.1:1" NOTIFY_API_KEY="$key" GITHUB_OUTPUT="$work/github-output" \
	NOTIFY_ACTION=create NOTIFY_MESSAGE="m" "$notify" >"$work/out" 2>&1; code=$?
check "no answer: a warning, exit 0" "$(yes_if [ "$code" = 0 ] && has "::warning::Suitaar alert: create got no answer.")"
check "never prints the key in any failure" "$(yes_if lacks "$key")"

echo "== only https, except a local test server"
: >"$work/requests"
env -i PATH="$PATH" NOTIFY_BASE_URL="http://example.com" NOTIFY_API_KEY="$key" GITHUB_OUTPUT="$work/github-output" \
	NOTIFY_ACTION=create NOTIFY_MESSAGE="m" NOTIFY_FAIL_ON_ERROR=true "$notify" >"$work/out" 2>&1; code=$?
check "a plain http base is refused" "$(yes_if [ "$code" = 1 ] && has "::error::Suitaar alert: the API address must use https")"
env -i PATH="$PATH" NOTIFY_ACTION=create NOTIFY_MESSAGE="m" NOTIFY_BASE_URL="http://127.0.0.1:$port" GITHUB_OUTPUT="$work/github-output" \
	"$notify" >"$work/out" 2>&1; code=$?
check "no key: a warning, no request" "$(yes_if [ "$code" = 0 ] && has "::warning::Suitaar alert: api-key is required" && [ ! -s "$work/requests" ])"

echo "== service"
: >"$work/requests"
env -i PATH="$PATH" NOTIFY_SERVICE=jira NOTIFY_API_KEY="$key" GITHUB_OUTPUT="$work/github-output" \
	NOTIFY_ACTION=create NOTIFY_MESSAGE="m" "$notify" >"$work/out" 2>&1; code=$?
check "an unknown service: a warning with the three values, no request" \
	"$(yes_if [ "$code" = 0 ] && has "::warning::Suitaar alert: service must be suitaar, opsgenie or opsgenie-eu, but was jira." && [ ! -s "$work/requests" ])"
env -i PATH="$PATH" NOTIFY_SERVICE=jira NOTIFY_API_KEY="$key" GITHUB_OUTPUT="$work/github-output" NOTIFY_FAIL_ON_ERROR=true \
	NOTIFY_ACTION=create NOTIFY_MESSAGE="m" "$notify" >"$work/out" 2>&1; code=$?
check "an unknown service with fail-on-error: exit 1" "$(yes_if [ "$code" = 1 ])"
check "suitaar" "$(yes_if [ "$("$base_url" suitaar)" = "https://suitaar.com/api/og" ])"
check "opsgenie" "$(yes_if [ "$("$base_url" opsgenie)" = "https://api.opsgenie.com" ])"
check "opsgenie-eu" "$(yes_if [ "$("$base_url" opsgenie-eu)" = "https://api.eu.opsgenie.com" ])"
"$base_url" jira >"$work/out" 2>&1; code=$?
check "base-url.sh, another value: exit 2 with the three values" "$(yes_if [ "$code" = 2 ] && has "service must be suitaar, opsgenie or opsgenie-eu, but was jira.")"

echo
echo "$passed of $total passed"
[ "$passed" = "$total" ]
