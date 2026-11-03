#!/usr/bin/env bash
# Merges a Renovate PR once CI passed on its head commit and someone approved that commit.
#
#   automerge.sh org <owner>                 every open Renovate PR in one org; GH_TOKEN is that org's app token
#   automerge.sh pr <owner/name> <number>    one PR
#
# DRY_RUN=true logs what would merge and merges nothing. REPOSITORIES, a comma-separated
# owner/name list, limits an org run to those repositories.
set -euo pipefail

# The Renovate app, as a PR's author login and as a search qualifier.
AUTHOR='renovate-appwrite[bot]'
SEARCH_AUTHOR='app/renovate-appwrite'
# The review bot. Its GitHub App was renamed from hansi-codes to appwrite.
BOT='appwrite[bot]'
BOT_APPS='appwrite hansi-codes'
BOT_CHECK='Hansi'
# Review apps whose check runs are verdicts, not CI, so they do not count as a repository having CI.
REVIEW_APPS='appwrite hansi-codes tenki-reviewer'

here=$(dirname "$0")
dry=${DRY_RUN:-false}

contains() {
  case " $1 " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

org() {
  local owner=$1 covered prs repository number

  covered=$("$here/repositories.sh" list | tr '\n' ' ')
  prs=$(gh search prs --owner "$owner" --author "$SEARCH_AUTHOR" --state open --limit 1000 \
    --json repository,number --jq '.[] | "\(.repository.nameWithOwner) \(.number)"')

  while read -r repository number; do
    [ -n "$repository" ] || continue
    if [ -n "${REPOSITORIES:-}" ] && ! contains "$(tr ',' ' ' <<< "$REPOSITORIES")" "$repository"; then
      continue
    fi
    if ! contains "$covered" "$repository"; then
      echo "$repository#$number: skip, repository is not covered by Renovate (excluded, archived, fork or split mirror)"
      continue
    fi
    # A separate process, so set -e still applies inside and one broken PR does not stop the rest.
    if ! "$0" pr "$repository" "$number"; then
      echo "::warning::$repository#$number: could not be evaluated"
    fi
  done <<< "$prs"
}

pr() {
  local repository=$1 number=$2 log="$1#$2"
  local pull sha runs statuses ci pending unsuccessful status reviews blocked approver login permission verdict method

  pull=$(gh api "repos/$repository/pulls/$number")
  sha=$(jq -r '.head.sha' <<< "$pull")

  if [ "$(jq -r '.user.login' <<< "$pull")" != "$AUTHOR" ]; then
    echo "$log: skip, not authored by $AUTHOR"; return
  fi
  if [ "$(jq -r '.state' <<< "$pull")" != 'open' ]; then
    echo "$log: skip, not open"; return
  fi
  if [ "$(jq -r '.draft' <<< "$pull")" = 'true' ]; then
    echo "$log: skip, draft"; return
  fi
  case "$(jq -r '.mergeable' <<< "$pull")" in
    true) ;;
    false) echo "$log: skip, has conflicts"; return ;;
    *) echo "$log: skip, mergeability not computed yet"; return ;;
  esac

  runs=$(gh api --paginate --slurp "repos/$repository/commits/$sha/check-runs?per_page=100" | jq '[.[].check_runs[]]')
  statuses=$(gh api "repos/$repository/commits/$sha/status")
  ci=$(jq --arg apps "$REVIEW_APPS" '[.[] | select(.app.slug as $slug | $apps | split(" ") | index($slug) | not)] | length' <<< "$runs")
  ci=$((ci + $(jq '.total_count' <<< "$statuses")))
  pending=$(jq -r '[.[] | select(.status != "completed") | .name] | if length > 3 then "\(length) checks, including \(.[:3] | join(", "))" else join(", ") end' <<< "$runs")
  unsuccessful=$(jq -r '[.[] | select(.status == "completed" and (.conclusion as $c | ["success", "skipped", "neutral"] | index($c) | not)) | "\(.name) (\(.conclusion))"] | join(", ")' <<< "$runs")
  status=$(jq -r 'if .total_count == 0 then "success" else .state end' <<< "$statuses")

  if [ "$ci" -eq 0 ]; then
    echo "$log: skip, repository has no CI on ${sha:0:7}"; return
  fi
  if [ -n "$pending" ]; then
    echo "$log: skip, checks pending: $pending"; return
  fi
  if [ -n "$unsuccessful" ]; then
    echo "$log: skip, checks failed: $unsuccessful"; return
  fi
  if [ "$status" != 'success' ]; then
    echo "$log: skip, commit status is $status"; return
  fi

  reviews=$(gh api --paginate --slurp "repos/$repository/pulls/$number/reviews?per_page=100" | jq '[.[][]]')
  # A reviewer's standing verdict is their latest approval, change request or dismissal; comments do not change it.
  blocked=$(jq -r '[.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
    | group_by(.user.login) | map(last | select(.state == "CHANGES_REQUESTED") | .user.login) | join(", ")' <<< "$reviews")
  if [ -n "$blocked" ]; then
    echo "$log: skip, changes requested by $blocked"; return
  fi

  approver=''
  if jq -e --arg sha "$sha" --arg bot "$BOT" 'any(.[]; .state == "APPROVED" and .commit_id == $sha and .user.login == $bot)' <<< "$reviews" > /dev/null; then
    approver=$BOT
  else
    for login in $(jq -r --arg sha "$sha" '[.[] | select(.state == "APPROVED" and .commit_id == $sha and .user.type == "User") | .user.login] | unique | .[]' <<< "$reviews"); do
      permission=$(gh api "repos/$repository/collaborators/$login/permission" --jq '.permission' || echo 'none')
      if [ "$permission" = 'admin' ] || [ "$permission" = 'write' ]; then
        approver=$login
        break
      fi
    done
  fi
  if [ -z "$approver" ]; then
    verdict=$(jq -r --arg apps "$BOT_APPS" --arg name "$BOT_CHECK" '[.[] | select(.name == $name and .status == "completed" and (.app.slug as $slug | $apps | split(" ") | index($slug)))] | last | .output.title // ""' <<< "$runs")
    if [[ "$verdict" == 'Tier S'* ]]; then
      approver="$BOT_CHECK Tier S"
    fi
  fi
  if [ -z "$approver" ]; then
    echo "$log: skip, ${sha:0:7} is not approved by $BOT or a maintainer${verdict:+ ($BOT_CHECK: $verdict)}"; return
  fi

  method=$(merge_method "$repository" "$(jq -r '.base.ref' <<< "$pull")")
  if [ -z "$method" ]; then
    echo "::warning::$log: no merge method is allowed"; return
  fi

  if [ "$dry" = 'true' ]; then
    echo "$log: would merge ${sha:0:7} ($method), CI green ($ci checks), approved by $approver"; return
  fi
  if gh pr merge "$number" --repo "$repository" "--$method" --match-head-commit "$sha"; then
    echo "$log: merged ${sha:0:7} ($method), CI green ($ci checks), approved by $approver"
  else
    echo "::warning::$log: merge of ${sha:0:7} ($method) was refused"
  fi
}

# Squash if allowed, else merge, else rebase, honouring both repository settings and branch rulesets.
merge_method() {
  local repository=$1 branch=$2 settings rules method
  # GraphQL, because the REST repository omits the allow_*_merge settings for tokens without admin access.
  settings=$(gh repo view "$repository" --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed --jq '[
    (select(.squashMergeAllowed) | "squash"),
    (select(.mergeCommitAllowed) | "merge"),
    (select(.rebaseMergeAllowed) | "rebase")
  ] | join(" ")')
  rules=$(gh api "repos/$repository/rules/branches/$branch" --jq '[.[] | select(.type == "pull_request") | .parameters.allowed_merge_methods // empty]')
  for method in squash merge rebase; do
    if contains "$settings" "$method" && jq -e --arg method "$method" 'all(.[]; index($method))' <<< "$rules" > /dev/null; then
      echo "$method"
      return
    fi
  done
}

case "${1:-}" in
  org) org "$2" ;;
  pr) pr "$2" "$3" ;;
  *) echo "usage: $0 org <owner> | pr <owner/name> <number>" >&2; exit 2 ;;
esac
