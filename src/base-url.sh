#!/usr/bin/env bash
# The base URL of the Opsgenie-compatible API of a service (the input `service`; notify.sh calls
# it). The paths after the base (/v2/alerts, /v2/heartbeats/…) are the same for all three.
#
#   src/base-url.sh suitaar|opsgenie|opsgenie-eu
set -euo pipefail

case "${1:-}" in
suitaar) echo "https://suitaar.com/api/og" ;;
opsgenie) echo "https://api.opsgenie.com" ;;
opsgenie-eu) echo "https://api.eu.opsgenie.com" ;;
*)
	echo "service must be suitaar, opsgenie or opsgenie-eu, but was ${1:-empty}." >&2
	exit 2
	;;
esac
