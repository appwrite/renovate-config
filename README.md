# renovate-config

Shared [Renovate](https://docs.renovatebot.com/) setup for the `appwrite`, `appwrite-labs`, `open-runtimes` and `utopia-php` organizations. Renovate opens every dependency PR. Dependabot stays on for alerts only: the Security tab, the #security relay, and the alerts Renovate turns into fix PRs.

## What repositories get

Every repository the `renovate appwrite` GitHub App is installed on is covered without a `renovate.json` of its own.

| Update | When | How it arrives |
| --- | --- | --- |
| Vulnerability fixes (GitHub alerts and [OSV](https://osv.dev/)) | As soon as a fix exists, ignoring the schedule and release age | One PR per package, labelled `security` |
| Minor and patch updates | Weekly, once a release is 7 days old | One grouped PR, "all non-major dependencies" |
| Major updates | Weekly, once a release is 7 days old | One PR per package |
| Lock file maintenance | Weekly | One PR that refreshes the lock file, picking up transitive fixes inside existing ranges |
| GitHub Actions | With the above | Pinned by commit digest |

Each repository also gets a Dependency Dashboard issue listing pending and rate-limited updates, plus a list of known vulnerabilities from OSV that no update fixes yet, such as advisories with no patched release or fixes that need a major upgrade. That list is the place to look for what Renovate will not handle on its own.

## Files

| File | Purpose |
| --- | --- |
| `default.json` | The shared preset (`github>appwrite/renovate-config`). Change update policy here. |
| `org-inherited-config.json` | Org-level overrides for `appwrite` repositories (`appwrite-labs/renovate-config` has one for that org). The preset itself is applied to every org by `global.json`, so an org needs no `renovate-config` repository. |
| `global.json` | Runner settings: extends the preset for every repository, turns off onboarding, enables `inheritConfig`, and lists the post-upgrade commands repositories may run. |
| `.github/workflows/renovate.yml` | The runner. |
| `.github/workflows/automerge.yml` | Merges approved Renovate PRs with green CI. |
| `.github/workflows/release-images.yml` | Publishes patch releases of image repositories with Renovate updates. |
| `.github/workflows/report.yml` | Posts open security PRs and their blockers to #security. |
| `.github/scripts/repositories.sh` | The repositories Renovate covers: exclusions, forks and split mirrors. Shared by both workflows. |
| `.github/scripts/automerge.sh` | The auto-merge decision for one org or one PR. |
| `.github/scripts/release-images.sh` | The release decision for image repositories, and the list of them. |
| `.github/scripts/report.sh` | Collects, renders and posts the security PR report. |
| `.github/workflows/validate.yml` | Validates the config files on every PR. |
| `.github/workflows/verify.yml` | Reusable workflow that installs, builds and tests a repository without CI of its own. |

## How it runs

The `renovate` workflow runs daily at 06:00 UTC:

1. `plan` mints an app token per org, lists the repositories the app is installed on, drops archived repositories, forks (except those listed in `FORKS`) and exclusions (both in `.github/scripts/repositories.sh`), and splits the rest into chunks of 40.
2. `renovate <org> <n>/<total>` runs Renovate on one chunk with its own token. An app token lasts one hour, so chunks keep each job well inside it, and a job stops at 55 minutes.

The app's client ID and private key live in the `renovate` environment, which only `main` can deploy to, so a workflow edited on another branch cannot read them. An org without the app installed is skipped with a warning.

### Running it by hand

Actions, then **renovate**, then **Run workflow**:

- **dryRun** logs what Renovate would change and opens nothing.
- **debug** turns on debug logging.
- **repositories** runs a comma-separated list instead of every repository, for example `appwrite/console,appwrite/mcp`. All entries must belong to one org.

## Auto-merge

The `automerge` workflow runs every 30 minutes and merges a Renovate PR only when CI passed and someone approved it. Every condition must hold for the PR's current head commit:

1. The PR is authored by `renovate-appwrite[bot]`, open, not a draft, has no conflicts, and its repository is covered by the runner (the same exclusions, forks and split mirrors as `plan`).
2. CI passed: at least one check run or commit status exists (a repository without CI never auto-merges; skipped check runs and the verify workflow's `detect projects` job do not count), no check run is pending, every check run concluded success, skipped or neutral, and the combined commit status is success. Review bot check runs (Hansi, Tenki) are verdicts, not CI, so they are left out of this step and a non-S Hansi tier does not block a maintainer's approval.
3. It is approved: an `APPROVED` review on the head commit from the review bot (`appwrite[bot]`, formerly `hansi-codes[bot]`) or from a user with write, maintain or admin access, or the review bot's `Hansi` check reporting Tier S on the head commit. A major update, including a security fix that needs one, only counts a user's approval. No reviewer's latest review requests changes.

It then merges with the org's app token, squashing if the repository and its branch rulesets allow it, else with a merge commit, else by rebase, and passes `--match-head-commit` so a push in between stops the merge. Branch protection still applies: a refused merge is logged as a warning and retried on the next run. Every PR gets one log line with the decision and the reason.

To check without merging, run **automerge** by hand with **dryRun**. **repositories** limits the run to a comma-separated list of repositories. Locally, `DRY_RUN=true .github/scripts/automerge.sh pr <owner/name> <number>` prints the decision for one PR with your own `gh` login, without the repository coverage check.

## Verifying repositories without CI

A repository with no checks never auto-merges. If it has no CI of its own, add `.github/workflows/verify.yml` to it (use the default branch's name if it is not `main`):

```yaml
name: verify
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  verify:
    uses: appwrite/renovate-config/.github/workflows/verify.yml@main
```

It finds every project in the repository from its tracked manifests and runs one `build <directory>` job per project directory:

| Project | Install | Then |
| --- | --- | --- |
| `package.json` | `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile` / `--immutable` or `bun install --frozen-lockfile`, from `packageManager` or the lockfile; `npm install` when there is no lockfile | `run build` and `run test` when the scripts exist |
| `composer.json` | `composer install` | `composer test` when the script exists |
| `uv.lock` | `uv sync --locked` | `pytest` when there are `test_*.py` or `*_test.py` files |
| `requirements.txt`, `pyproject.toml` with `[project]` or `[build-system]` | `pip install -r requirements.txt` / `pip install .` | the same |
| `go.mod` | | `go build ./... && go vet ./...` |
| `Cargo.toml` | | `cargo build` |
| `pubspec.yaml` | `dart pub get`, or `flutter pub get` for Flutter apps | |

Node defaults to 24 and Python to 3.13 unless `.nvmrc`, `.node-version`, `.python-version` or `requires-python` say otherwise. Workspace members without their own lockfile are left to the workspace root. Swift, Gradle, Ruby, Maven, Deno and .NET projects are skipped with a notice.

To choose the projects yourself, pass `directories` (space or newline separated, `.` is the root). A listed directory with no supported project fails the check:

```yaml
    with:
      directories: server-side-rendering example-blog
```

When nothing is found the `build` jobs are skipped and only `detect projects` runs, which auto-merge does not count, so the repository still counts as having no CI instead of passing on nothing. The jobs check out with a read-only `GITHUB_TOKEN` and receive no secrets, because they run dependency install scripts from the PR.

## Per-repository settings

Add a `renovate.json` to the repository; it is merged on top of the shared config.

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "ignorePaths": ["examples/**"],
  "packageRules": [
    { "matchPackageNames": ["react", "react-dom"], "groupName": "react" }
  ]
}
```

To turn Renovate off for a repository, commit `{ "enabled": false }` as its `renovate.json`.

## Excluded repositories

- `utopia-php` split mirrors: the `plan` job reads `appwrite/appwrite/packages` and skips every matching `utopia-php/<name>`, whatever the app installation covers, and a manual run naming one is rejected. Packages absorbed into `appwrite/appwrite/packages` have `utopia-php/<name>` repositories that are split mirrors, so they must never get Renovate PRs; their dependencies are updated in the monorepo. Add a repository to the installation only while it is still developed in `utopia-php`.

- `appwrite/sdk-for-*`: generated SDKs. Their dependencies are updated in `appwrite/sdk-generator` templates.
- `appwrite/sdk-generator`, `appwrite-labs/cluster-configuration-generator`, `appwrite-labs/application-configuration`: still run Renovate from their own workflows. To move one here, delete its workflow and remove it from `EXCLUDED` in `.github/scripts/repositories.sh`.

## Changing the config

Open a PR here. Validate locally with the same Renovate version the runner uses:

```sh
npx --yes --package renovate@44.202.1 -- renovate-config-validator --strict default.json org-inherited-config.json global.json
```

After merging, dispatch a dry run on one or two repositories before the next scheduled run.

## Troubleshooting

- **A PR says the lock file could not be updated.** The package manager failed inside Renovate, usually a peer dependency conflict or an outdated lock file. Fix it in that repository; Renovate retries on its next run.
- **A repository gets no PRs.** Check that the app is installed on it, that it is not archived or excluded, and look for its name in the `plan` job log.
- **`bad-credentials` near the end of a job.** The chunk took longer than the token lasts. Lower `CHUNK` in the workflow.

## Security PR report

The `report` workflow runs daily at 07:30 UTC and lists every open Renovate security PR with its severity, age and the reason auto-merge is holding it, using the same decision as `automerge.sh`. It posts to the #security Discord forum on Mondays, and on any day a critical or high fix reaches 3 days open.

It needs a webhook for that forum, stored as `SECURITY_DISCORD_WEBHOOK` in the `renovate` environment; without one the run logs a warning and posts nothing. **Run workflow** posts straight away.

This repository is public, so the report only goes to Discord. It isn't written to logs, artifacts or issues, because it lists unfixed vulnerabilities, including in private repositories.

## Image releases

An image only picks up a new base when it is rebuilt, and image repositories only build from a release or a tag. The `release-images` workflow runs daily at 08:00 UTC and publishes a patch release of each repository listed in `release-images.sh`, when its default branch has changes since the latest version tag and:

- every commit since that tag is from `renovate-appwrite[bot]`, so nobody else's unfinished work ships
- something outside `.github/` changed, because workflow updates don't change the image

To add a repository, check that its build runs from a release or a tag, then add it to `REPOSITORIES`. Add its org to the workflow's matrix if it's a new one. Run **release-images** by hand with **dryRun** to see what it would do.
