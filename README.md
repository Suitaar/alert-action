# Suitaar Alert (Opsgenie-compatible)

A GitHub Action that creates, closes, acknowledges and notes alerts, and pings heartbeats, in
[Suitaar](https://suitaar.com) or in Opsgenie (US or EU). It uses the Opsgenie Alert and Heartbeat
API, which Suitaar also speaks. So a workflow moves from Opsgenie to Suitaar by changing `service`
and the key.

- A composite action in bash: `curl` and `jq` only, no Node, no build.
- A failed call is a warning by default, never a failed workflow (`fail-on-error: "true"` changes it).
- The key stays in an environment variable: it is masked, and it never appears on a command line or in the log.

**Tested:** against Suitaar (the end-to-end workflow), and against a local stand-in of the API for
each action. Opsgenie (US and EU) gets the same requests, as Opsgenie documents them; this
repository does not test against Opsgenie itself.

## Alert when a job fails, close it when the job passes again

```yaml
- name: Alert on failure
  if: failure()
  uses: Suitaar/alert-action@<commit sha>  # v0.1.0
  with:
    api-key: ${{ secrets.SUITAAR_KEY }}
    alias: ci-${{ github.workflow }}-${{ github.ref_name }}
    message: "${{ github.workflow }} failed on ${{ github.ref_name }}"
    description: "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
    priority: P2
    source: GitHub Actions

- name: Close on success
  if: success()
  uses: Suitaar/alert-action@<commit sha>  # v0.1.0
  with:
    api-key: ${{ secrets.SUITAAR_KEY }}
    action: close
    alias: ci-${{ github.workflow }}-${{ github.ref_name }}
    user: ${{ github.actor }}
```

The same `alias` makes a repeat count on one alert, and lets the close find it.

## Heartbeat on a schedule

```yaml
on:
  schedule:
    - cron: "0 3 * * *"
jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - run: ./backup.sh
      - uses: Suitaar/alert-action@<commit sha>  # v0.1.0
        with:
          api-key: ${{ secrets.SUITAAR_KEY }}
          action: heartbeat
          heartbeat: nightly-backup
```

When the pings stop, Suitaar (or Opsgenie) opens an alert. Make the heartbeat in the service first.

## Inputs

| Input | Required | Description |
|---|---|---|
| `api-key` | yes | The key of a Suitaar source, or an Opsgenie API key. Use a secret. |
| `service` | no | `suitaar` (default), `opsgenie` (US) or `opsgenie-eu`. |
| `action` | no | `create` (default), `close`, `acknowledge`, `note` or `heartbeat`. |
| `alias` | for close, acknowledge, note | The key of the alert. |
| `message` | for create | The title of the alert. |
| `description` | no | The text of the alert. |
| `priority` | no | `P1` to `P5`. Without it, the service's default (P3). |
| `tags` | no | Tags, separated by commas. |
| `details` | no | Extra fields, a JSON object of texts, for example `{"run": "42"}`. |
| `note` | for note | A note. Also kept with create, close and acknowledge. |
| `user` | no | Who did it, for example `${{ github.actor }}`. |
| `source` | no | Where the alert comes from, for example `GitHub Actions`. |
| `heartbeat` | for heartbeat | The name of the heartbeat. |
| `fail-on-error` | no | `"true"`: a failed call fails the step. `"false"` (default): a warning only. |

## Outputs

| Output | Description |
|---|---|
| `status` | The HTTP status of the answer: `202` when the service took the request, `000` when no answer came. |
| `request-id` | The request id of the answer. |

## Pin a commit

Use a full commit SHA in `uses:`, with the version in a comment. A tag can move; a commit cannot.

## Development

```sh
test/notify-test.sh      # the script test against a local stand-in (needs bash, python3, jq, curl)
shellcheck src/*.sh test/*.sh
```

The workflow **End-to-end** runs the action against suitaar.com, by hand only, with the
repository secret `SUITAAR_TEST_KEY` (the key of a test source).

## License

MIT, see [LICENSE](LICENSE).
