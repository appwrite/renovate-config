#!/usr/bin/env bash
# Publishes a patch release of an image repository once Renovate's updates are on its default
# branch. An image only picks up a new base when it is rebuilt, and these repositories only build
# from a release or a tag. A release creates the tag too, so it starts either kind of workflow.
#
#   release-images.sh <owner>    every listed repository of one org; GH_TOKEN is that org's app token
#
# DRY_RUN=true logs what would be released and publishes nothing.
set -euo pipefail

AUTHOR='renovate-appwrite[bot]'
# Repositories released automatically, added one at a time as each is checked.
REPOSITORIES='appwrite/docker-browser'

dry=${DRY_RUN:-false}

release() {
  local repository=$1 branch tag compare others files head next
  branch=$(gh api "repos/$repository" --jq '.default_branch')
  tag=$(gh api --paginate "repos/$repository/tags?per_page=100" --jq '.[].name' | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
  if [ -z "$tag" ]; then
    echo "::warning::$repository: no version tag to release from"; return
  fi

  compare=$(gh api "repos/$repository/compare/$tag...$branch")
  if [ "$(jq -r '.ahead_by' <<< "$compare")" = '0' ]; then
    echo "$repository: $tag is current"; return
  fi
  # Someone else's commit may not be ready to ship, so its owner decides when to release.
  others=$(jq -r --arg author "$AUTHOR" '[.commits[] | select(.author.login != $author) | .sha[:7]] | join(", ")' <<< "$compare")
  if [ -n "$others" ]; then
    echo "$repository: skip, commits since $tag not from Renovate: $others"; return
  fi
  # Workflow updates change nothing in the image.
  files=$(jq -r '[.files[].filename | select(startswith(".github/") | not)] | length' <<< "$compare")
  if [ "$files" = '0' ]; then
    echo "$repository: skip, only workflows changed since $tag"; return
  fi

  head=$(jq -r '.commits[-1].sha' <<< "$compare")
  next=$(awk -F. -v OFS=. '{ $3 += 1; print }' <<< "$tag")
  if [ "$dry" = 'true' ]; then
    echo "$repository: would release $next at ${head:0:7}"; return
  fi
  gh release create "$next" --repo "$repository" --target "$head" --title "$next" --generate-notes > /dev/null
  echo "$repository: released $next at ${head:0:7}"
}

owner=${1:?usage: $0 <owner>}
for repository in $REPOSITORIES; do
  if [[ "$repository" == "$owner/"* ]]; then
    release "$repository"
  fi
done
