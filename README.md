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
| `.github/workflows/validate.yml` | Validates the config files on every PR. |

## How it runs

The `renovate` workflow runs daily at 06:00 UTC:

1. `plan` mints an app token per org, lists the repositories the app is installed on, drops archived repositories, forks (except those listed in `FORKS`) and exclusions, and splits the rest into chunks of 40.
2. `renovate <org> <n>/<total>` runs Renovate on one chunk with its own token. An app token lasts one hour, so chunks keep each job well inside it, and a job stops at 55 minutes.

The app's client ID and private key live in the `renovate` environment, which only `main` can deploy to, so a workflow edited on another branch cannot read them. An org without the app installed is skipped with a warning.

### Running it by hand

Actions, then **renovate**, then **Run workflow**:

- **dryRun** logs what Renovate would change and opens nothing.
- **debug** turns on debug logging.
- **repositories** runs a comma-separated list instead of every repository, for example `appwrite/console,appwrite/mcp`. All entries must belong to one org.

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

- `utopia-php`: the app is installed on selected repositories only. Packages absorbed into `appwrite/appwrite/packages` have `utopia-php/<name>` repositories that are split mirrors, so they must never get Renovate PRs; their dependencies are updated in the monorepo. Add a repository to the installation only while it is still developed in `utopia-php`.

- `appwrite/sdk-for-*`: generated SDKs. Their dependencies are updated in `appwrite/sdk-generator` templates.
- `appwrite/sdk-generator`, `appwrite-labs/cluster-configuration-generator`, `appwrite-labs/application-configuration`: still run Renovate from their own workflows. To move one here, delete its workflow and remove it from `EXCLUDED` in `.github/workflows/renovate.yml`.

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
