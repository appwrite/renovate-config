#!/usr/bin/env bash
# Reports open Renovate security PRs and why each hasn't merged. This repository is public and its
# Actions logs can be read by anyone, so rows only ever go to a file and to the private #security channel.
#
#   report.sh org <owner>    one TSV row per PR on stdout; GH_TOKEN is that org's app token
#   report.sh render <rows>  the full report as Markdown on stdout
#   report.sh post <rows>    posts to SECURITY_DISCORD_WEBHOOK on Mondays, when a PR becomes overdue, or with FORCE=true
set -euo pipefail

SEARCH_AUTHOR='app/renovate-appwrite'
# A critical or high fix still open after this many days is overdue.
OVERDUE_DAYS=3

here=$(dirname "$0")

org() {
  local owner=$1 covered prs row repository number reason
  covered=" $("$here/repositories.sh" list | tr '\n' ' ') "

  prs=$(gh search prs --owner "$owner" --author "$SEARCH_AUTHOR" --label security --state open --limit 1000 \
    --json repository,number,url,createdAt,body \
    --jq '.[] | {
      repository: .repository.nameWithOwner,
      number,
      url,
      age: ((now - (.createdAt | fromdate)) / 86400 | floor),
      severity: ([.body | scan("(?:CVSS Score:[^\\n]*\\(|Severity: )(Critical|High|Medium|Low)") | .[0]] as $found
        | (["Critical", "High", "Medium", "Low"] | map(select(. as $level | $found | index($level))) | first) // "Unknown")
    }')
}

evaluate() {
  DRY_RUN=true "$here/automerge.sh" pr "$1" "$2" 2> /dev/null | tail -n 1 || true
}

# Rows ordered by severity, then oldest first, as "rank severity age name url reason".
sorted() {
  awk -F '\t' -v OFS='\t' '{
    rank = $1 == "Critical" ? 0 : $1 == "High" ? 1 : $1 == "Medium" ? 2 : $1 == "Low" ? 3 : 4
    print rank, $0
  }' "$1" | sort -t "$(printf '\t')" -k1,1n -k3,3nr
}

render() {
  local rows=$1
  echo "# Open security PRs"
  echo
  echo "$(wc -l < "$rows" | tr -d ' ') open. Critical or high fixes open for ${OVERDUE_DAYS}+ days are marked overdue."
  echo
  echo "## By blocker"
  echo
  # Commit hashes and details differ per PR, so they would split a blocker into many lines.
  cut -f 5 "$rows" | sed -E 's/(^| )[0-9a-f]{7}( |$)/ /; s/^ //; s/[:(].*//; s/ on *$//; s/ *$//' | sort | uniq -c | sort -rn | awk '{ count = $1; $1 = ""; print "-" $0 ": " count }'

  while read -r row; do
    [ -n "$row" ] || continue
    repository=$(jq -r '.repository' <<< "$row")
    number=$(jq -r '.number' <<< "$row")
    [[ "$covered" == *" $repository "* ]] || continue
    reason=$(evaluate "$repository" "$number")
    # GitHub computes mergeability when first asked, so a second look usually has the answer.
    if [[ "$reason" == *'mergeability not computed yet' ]]; then
      sleep 5
      reason=$(evaluate "$repository" "$number")
    fi
    reason=${reason#"$repository#$number: "}
    reason=${reason#skip, }
    if [[ "$reason" == 'would merge'* ]]; then
      reason='approved with green CI, but not merged'
    fi
    jq -r --arg reason "${reason:-could not be evaluated}" '[.severity, .age, "\(.repository)#\(.number)", .url, $reason] | @tsv' <<< "$row"
  done <<< "$prs"
  echo
  echo "## PRs"
  echo
  echo "| Severity | Age | PR | Blocker |"
  echo "| --- | --- | --- | --- |"
  sorted "$rows" | awk -F '\t' -v overdue="$OVERDUE_DAYS" '{
    flag = ($1 <= 1 && $3 >= overdue) ? " (overdue)" : ""
    print "| " $2 flag " | " $3 "d | [" $4 "](" $5 ") | " $6 " |"
  }'
}

post() {
  local rows=$1 total overdue fresh message report
  : "${SECURITY_DISCORD_WEBHOOK:?SECURITY_DISCORD_WEBHOOK is required}"
  total=$(wc -l < "$rows" | tr -d ' ')
  overdue=$(awk -F '\t' -v days="$OVERDUE_DAYS" '($1 == "Critical" || $1 == "High") && $2 >= days' "$rows" | wc -l | tr -d ' ')
  fresh=$(awk -F '\t' -v days="$OVERDUE_DAYS" '($1 == "Critical" || $1 == "High") && $2 == days' "$rows" | wc -l | tr -d ' ')

  if [ "${FORCE:-false}" != 'true' ] && [ "$(date -u +%u)" != '1' ] && [ "$fresh" -eq 0 ]; then
    echo "Nothing to post today."
    return
  fi

  message="**$total open security PRs, $overdue overdue.**"
  message+=$'\n'"$(sorted "$rows" | awk -F '\t' -v days="$OVERDUE_DAYS" '$1 <= 1 && $3 >= days { print "- " $2 ", " $3 "d: [" $4 "](<" $5 ">): " $6 }' | head -n 10 | cut -c 1-170)"
  report=$(mktemp)
  render "$rows" > "$report"

  # thread_name is required by forum channels, and no mentions are allowed from report text.
  curl --fail --silent --show-error --output /dev/null "$SECURITY_DISCORD_WEBHOOK" \
    -F "payload_json=$(jq -n --arg content "$message" --arg name "Open security PRs $(date -u +%F)" \
      '{content: $content[:1900], thread_name: $name, allowed_mentions: {parse: []}}')" \
    -F "files[0]=@$report;filename=security-prs.md;type=text/markdown"
  echo "Posted."
}

case "${1:-}" in
  org) org "$2" ;;
  render) render "$2" ;;
  post) post "$2" ;;
  *) echo "usage: $0 org <owner> | render <rows> | post <rows>" >&2; exit 2 ;;
esac
