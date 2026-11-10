#!/usr/bin/env bash
# The repositories Renovate covers, shared by the renovate and automerge workflows.
#
#   repositories.sh mirrors        utopia-php split mirrors of appwrite/appwrite/packages, space separated
#   repositories.sh list           covered repositories of the org GH_TOKEN, an installation token, belongs to; one per line
set -euo pipefail

# Generated SDKs are updated through sdk-generator. These repositories run Renovate from
# their own workflows, so they are skipped here to avoid processing them twice.
EXCLUDED='appwrite/sdk-generator appwrite-labs/cluster-configuration-generator appwrite-labs/application-configuration'

# Forks are skipped unless listed here; each opts in with forkProcessing in its renovate.json.
FORKS='appwrite/grafana-oncall appwrite-labs/gcrunner'

mirrors() {
  # Packages absorbed into appwrite/appwrite keep a utopia-php/<name> repository that
  # bin/monorepo split pushes to; a PR there would be overwritten, so never process one.
  gh api repos/appwrite/appwrite/contents/packages \
    --jq '[.[] | select(.type == "dir") | "utopia-php/\(.name)"] | join(" ")'
}

list() {
  local excluded
  excluded="$EXCLUDED $(mirrors)"
  gh api --paginate /installation/repositories \
    --jq '.repositories[] | select(.archived | not) | [.full_name, .fork] | @tsv' \
    | jq -rR --arg excluded "$excluded" --arg forks "$FORKS" 'split("\t") | {name: .[0], fork: (.[1] == "true")}
        | select((.fork | not) or (.name as $name | $forks | split(" ") | index($name)))
        | select((.name | split("/")[1] | startswith("sdk-for-")) | not)
        | select(.name as $name | ($excluded | split(" ") | index($name)) | not)
        | .name'
}

case "${1:-}" in
  mirrors) mirrors ;;
  list) list ;;
  *) echo "usage: $0 mirrors | list" >&2; exit 2 ;;
esac
