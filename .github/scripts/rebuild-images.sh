#!/usr/bin/env bash
# Rebuilds an image repository's default branch and publishes a patch release when the fresh
# build has fewer fixable high or critical vulnerabilities than the latest published release.
# Packages from the base image and from `apk add`/`apt-get install` only pick up distro fixes
# when the image is rebuilt, and Renovate never triggers that while the base digest stays put.
# Releasing only on a strict improvement stops a fix that needs a new base from looping.
#
#   rebuild-images.sh plan              resolve the head commit, latest tag and image refs; writes step outputs
#   rebuild-images.sh count <image>     fixable high and critical vulnerabilities in an image
#   rebuild-images.sh release           publish the next patch version at the head commit
#
# Inputs are environment variables set by the workflow: REPOSITORY, PUBLISHED and CANDIDATE
# (image refs with {tag} and {sha} placeholders), and for release HEAD, NEXT, MODE and DRY_RUN.
# shellcheck disable=SC2153 # the inputs above are environment variables
set -euo pipefail

TRIVY='aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c'

plan() {
  local branch head tag published candidate
  branch=$(gh api "repos/$REPOSITORY" --jq '.default_branch')
  head=$(gh api "repos/$REPOSITORY/commits/$branch" --jq '.sha')
  tag=$(gh api --paginate "repos/$REPOSITORY/tags?per_page=100" --jq '.[].name' | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
  if [ -z "$tag" ]; then
    echo "::error::$REPOSITORY: no version tag to compare with"; exit 1
  fi
  published=${PUBLISHED//'{tag}'/$tag}
  candidate=${CANDIDATE//'{sha}'/$head}
  # A release from earlier today may still be building; compare once its image exists.
  if ! docker buildx imagetools inspect "$published" > /dev/null 2>&1; then
    echo "$REPOSITORY: skip, $published is not published yet"
    echo "| $REPOSITORY | $tag | | | not published yet |" >> "$GITHUB_STEP_SUMMARY"
    echo 'skip=true' >> "$GITHUB_OUTPUT"; return
  fi
  {
    echo "owner=${REPOSITORY%%/*}"
    echo "name=${REPOSITORY#*/}"
    echo "head=$head"
    echo "tag=$tag"
    echo "next=$(awk -F. -v OFS=. '{ $3 += 1; print }' <<< "$tag")"
    echo "published=$published"
    echo "candidate=$candidate"
  } >> "$GITHUB_OUTPUT"
}

count() {
  local image=$1 source
  # A local build is scanned from the daemon; a published image from its registry.
  if docker image inspect "$image" > /dev/null 2>&1; then
    source=(--image-src docker)
  else
    source=(--image-src remote --platform linux/amd64)
  fi
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache "$TRIVY" \
    image --quiet --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL --format json "${source[@]}" "$image" \
    | jq '[.Results[]?.Vulnerabilities[]? | "\(.VulnerabilityID) \(.PkgName)"] | unique | length'
}

release() {
  if [ "${DRY_RUN:-false}" = 'true' ]; then
    echo "$REPOSITORY: would release $NEXT at ${HEAD:0:7}"; return
  fi
  if [ "$MODE" = 'tag' ]; then
    # The repository's own workflow creates the release from a pushed tag.
    gh api "repos/$REPOSITORY/git/refs" -f ref="refs/tags/$NEXT" -f sha="$HEAD" > /dev/null
  else
    gh release create "$NEXT" --repo "$REPOSITORY" --target "$HEAD" --title "$NEXT" \
      --notes 'Rebuilt with updated base/distro packages.' --generate-notes > /dev/null
  fi
  echo "$REPOSITORY: released $NEXT at ${HEAD:0:7}"
}

case "${1:-}" in
  plan) plan ;;
  count) count "${2:?usage: $0 count <image>}" ;;
  release) release ;;
  *) echo "usage: $0 plan | count <image> | release" >&2; exit 2 ;;
esac
