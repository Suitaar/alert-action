#!/usr/bin/env bash
# One call to the Opsgenie-compatible Alert or Heartbeat API (Suitaar, or Opsgenie in the US or the
# EU). action.yml sets the inputs as NOTIFY_* variables and the base URL from `service`.
#
#   NOTIFY_SERVICE    suitaar (default), opsgenie or opsgenie-eu: the base URL (src/base-url.sh)
#   NOTIFY_BASE_URL   only for the tests: a local stand-in instead of the service. action.yml
#                     always sets it empty, so a workflow's own env cannot change where the key goes.
#   NOTIFY_RETRY_DELAYS  only for the tests: the waits in seconds before the second and third try
#                     (default "5 20"). action.yml always sets it empty.
#   NOTIFY_API_KEY    the key (never printed; it goes to curl through a config on stdin)
#   NOTIFY_ACTION     create, close, acknowledge, note or heartbeat
#   NOTIFY_ALIAS, NOTIFY_MESSAGE, NOTIFY_DESCRIPTION, NOTIFY_PRIORITY, NOTIFY_TAGS, NOTIFY_DETAILS,
#   NOTIFY_NOTE, NOTIFY_USER, NOTIFY_SOURCE, NOTIFY_HEARTBEAT, NOTIFY_FAIL_ON_ERROR
#
# Outputs (GITHUB_OUTPUT): status (the HTTP status, 000 without an answer) and request-id.
# A failure is a warning and exit 0, or with NOTIFY_FAIL_ON_ERROR=true an error and exit 1.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
action="${NOTIFY_ACTION:-create}"
output="${GITHUB_OUTPUT:-/dev/null}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# finish STATUS REQUEST-ID: the outputs.
finish() {
	echo "status=$1" >>"$output"
	echo "request-id=$2" >>"$output"
}

# fail TEXT: a warning, or an error that fails the step.
fail() {
	if [ "${NOTIFY_FAIL_ON_ERROR:-false}" = true ]; then
		echo "::error::Suitaar alert: $1"
		exit 1
	fi
	echo "::warning::Suitaar alert: $1"
	exit 0
}

# encode TEXT: the text as one URL path part.
encode() { jq -rn --arg value "$1" '$value | @uri'; }

[ -n "${NOTIFY_API_KEY:-}" ] || fail "api-key is required."
base="${NOTIFY_BASE_URL:-}"
if [ -z "$base" ]; then
	base=$("$here/base-url.sh" "${NOTIFY_SERVICE:-suitaar}" 2>"$work/service-error") || fail "$(cat "$work/service-error")"
fi
case "$base" in
https://*) ;;
http://127.0.0.1:* | http://localhost:*) ;;
*) fail "the API address must use https, but was ${base:-empty}." ;;
esac

case "$action" in
create)
	[ -n "${NOTIFY_MESSAGE:-}" ] || fail "message is required to create an alert."
	if [ -n "${NOTIFY_PRIORITY:-}" ] && [[ ! "$NOTIFY_PRIORITY" =~ ^P[1-5]$ ]]; then
		fail "priority must be P1, P2, P3, P4 or P5, but was $NOTIFY_PRIORITY."
	fi
	if [ -n "${NOTIFY_DETAILS:-}" ] && ! jq -e 'type == "object" and all(.[]; type == "string")' <<<"$NOTIFY_DETAILS" >/dev/null 2>&1; then
		fail "details must be a JSON object of texts, for example {\"run\": \"42\"}."
	fi
	method=POST
	path="/v2/alerts"
	body=$(jq -n --arg message "$NOTIFY_MESSAGE" --arg alias "${NOTIFY_ALIAS:-}" \
		--arg description "${NOTIFY_DESCRIPTION:-}" --arg priority "${NOTIFY_PRIORITY:-}" \
		--arg tags "${NOTIFY_TAGS:-}" --arg details "${NOTIFY_DETAILS:-}" --arg user "${NOTIFY_USER:-}" \
		--arg source "${NOTIFY_SOURCE:-}" --arg note "${NOTIFY_NOTE:-}" '
		{message: $message, alias: $alias, description: $description, priority: $priority,
		 tags: ($tags | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))),
		 details: (if $details == "" then {} else ($details | fromjson) end),
		 user: $user, source: $source, note: $note}
		| with_entries(select(.value != "" and .value != [] and .value != {}))')
	;;
close | acknowledge | note)
	[ -n "${NOTIFY_ALIAS:-}" ] || fail "alias is required to $action an alert."
	if [ "$action" = note ] && [ -z "${NOTIFY_NOTE:-}" ]; then fail "note is required to add a note."; fi
	method=POST
	segment=$action
	[ "$action" = note ] && segment=notes
	path="/v2/alerts/$(encode "$NOTIFY_ALIAS")/$segment?identifierType=alias"
	body=$(jq -n --arg user "${NOTIFY_USER:-}" --arg source "${NOTIFY_SOURCE:-}" --arg note "${NOTIFY_NOTE:-}" '
		{user: $user, source: $source, note: $note} | with_entries(select(.value != ""))')
	;;
heartbeat)
	[ -n "${NOTIFY_HEARTBEAT:-}" ] || fail "heartbeat is required to ping a heartbeat."
	method=GET
	path="/v2/heartbeats/$(encode "$NOTIFY_HEARTBEAT")/ping"
	body=""
	;;
*) fail "action must be create, close, acknowledge, note or heartbeat, but was $action." ;;
esac

# call: one request; sets status (000 without an answer). The key goes to curl as a config on
# stdin, never on a command line.
call() {
	rm -f "$work/headers" "$work/body"
	status=$(printf 'header = "Authorization: GenieKey %s"\n' "$NOTIFY_API_KEY" |
		curl -sS --max-time 15 -K - -X "$method" -H "Content-Type: application/json" ${body:+--data "$body"} \
			-D "$work/headers" -o "$work/body" -w '%{http_code}' "$base$path" 2>/dev/null)
	status=${status:-000}
}

# Up to 3 tries: again after no answer, a 5xx or a 429, never after another 4xx.
read -r -a delays <<<"${NOTIFY_RETRY_DELAYS:-5 20}"
call
for delay in "${delays[@]}"; do
	case "$status" in
	000) echo "Suitaar alert: $action got no answer, trying again in $delay s." ;;
	5?? | 429) echo "Suitaar alert: $action answered $status, trying again in $delay s." ;;
	*) break ;;
	esac
	sleep "$delay"
	call
done
request_id=$(jq -r '.requestId // empty' "$work/body" 2>/dev/null)
if [ -z "$request_id" ]; then
	request_id=$(sed -n 's/^[Xx]-[Rr]equest-[Ii]d: *//p' "$work/headers" 2>/dev/null | tr -d '\r' | head -n 1)
fi
finish "$status" "$request_id"

suffix=${request_id:+" (request $request_id)"}
case "$status" in
2??) echo "Suitaar alert: $action answered $status${suffix}." ;;
000) fail "$action got no answer." ;;
*)
	message=$(jq -r '.message // empty' "$work/body" 2>/dev/null | head -c 300)
	fail "$action answered $status${message:+: $message}${suffix}."
	;;
esac
