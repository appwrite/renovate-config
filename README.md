# renovate-config

Shared [Renovate](https://docs.renovatebot.com/) configuration for the Appwrite organization. Renovate opens every dependency PR; Dependabot stays on only for alerts (Security tab, the #security relay, and the alerts Renovate reads for vulnerability fixes).

- `default.json` is the preset: weekly grouped non-major updates, majors as separate PRs, a 7 day minimum release age, weekly lock file maintenance (picks up transitive fixes inside existing ranges), and vulnerability fixes from both GitHub alerts and OSV, which skip the schedule and release age.
- `org-inherited-config.json` is applied by Renovate (`inheritConfig`) to every repository it runs on. It extends the preset and turns off onboarding, so a repository needs no `renovate.json` to be covered.

`global.json` and `.github/workflows/renovate.yml` are the runner: a daily self-hosted Renovate using the `renovate appwrite` GitHub App (its credentials live in the `renovate` environment, deployable from `main` only). A plan job lists every repository the app is installed on in `appwrite` and `appwrite-labs` and splits them into chunks of 40, each run with its own app token because a token lasts one hour. Run it by hand from the Actions tab, with a dry run or a repository list for testing. Repositories that still run Renovate from their own workflow (`appwrite/sdk-generator`, `appwrite-labs/cluster-configuration-generator`, `appwrite-labs/application-configuration`) are excluded so they are not processed twice.

A repository that needs more (custom managers, ignored paths, extra rules) adds a `renovate.json`; it is merged on top of the inherited config. To turn Renovate off for a repository, commit a `renovate.json` with `{ "enabled": false }`.

Generated SDK repositories (`sdk-for-*`) are updated through `appwrite/sdk-generator`, so the runner skips them and Renovate never edits generated code.
