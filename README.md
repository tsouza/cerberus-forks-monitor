# cerberus-forks-monitor

Daily upstream-change monitor for the four cerberus fork repos. Lives
outside cerberus itself so the cron job is portable, and so its commit
history doesn't pollute the cerberus main branch.

This repo exists because **cerberus consumes only a narrow slice** of
each upstream parser, but Dependabot watches whole repositories. If
cerberus depended on `prometheus/prometheus` directly, Dependabot would
open a PR for every unrelated upstream change. By routing each upstream
through a fork that *we* control, we keep Dependabot focused on tags we
mint — and we only mint tags when something cerberus actually cares
about lands upstream.

## Architecture

```text
┌──────────────────────┐    upstream/main         ┌──────────────────────────┐
│ upstream repos       │ ───────────────────────► │ tsouza/<fork>            │
│ (prometheus, loki,   │   relevant-paths only    │   cerberus-<branch>      │
│  tempo, otel-c)      │   are forwarded as tags  │     ├── tag v0.0.1       │
└──────────────────────┘                          │     ├── tag v0.0.2       │
                                                  │     └── ...               │
                                                  └────────────┬─────────────┘
                                                               │
                                       Dependabot watches tags │
                                                               ▼
                                                  ┌──────────────────────────┐
                                                  │ tsouza/cerberus go.mod   │
                                                  │   replace directives use │
                                                  │   tsouza/<fork>@vX.Y.Z   │
                                                  └──────────────────────────┘
```

## Daily flow

1. **GitHub Actions cron** triggers `daily.yml` at 10:17 UTC.
2. The workflow checks out this repo and runs `monitor.sh`.
3. For each entry in [`monitor.yml`](monitor.yml):
   - Clone the fork. Fetch `upstream/main`.
   - Find the latest semver tag on the long-lived cerberus branch.
   - Compute `git log <last_tag>..upstream/main -- <relevant_paths>`.
   - If empty: skip silently.
   - If non-empty: rebase the cerberus branch onto `upstream/main`, run
     the configured subtree tests, push, and mint a new patch-bumped tag
     (plus per-submodule tags for the collector-contrib monorepo).
4. On rebase conflict or red tests, the monitor **opens an issue** in
   this repo and does not push. A human resolves the conflict locally
   and re-runs the workflow via the `workflow_dispatch` button.

## Configuration

[`monitor.yml`](monitor.yml) is the single source of truth. Each `deps`
entry binds one upstream to one fork. The fields:

| Field                | Purpose                                                                 |
| -------------------- | ----------------------------------------------------------------------- |
| `name`               | Short identifier used in logs + issue titles.                           |
| `upstream`           | `owner/repo` of the upstream we mirror.                                 |
| `fork`               | `owner/repo` of our fork. Must be writable by `FORKS_PAT`.              |
| `fork_branch`        | The long-lived `cerberus-*` branch the monitor maintains.               |
| `tag_prefix`         | The semver major version. Must match Go module path conventions.        |
| `relevant_paths`     | Passed to `git log -- <paths>`. Only commits touching these trigger work. |
| `test_subtrees`      | Passed to `go test`. Each entry is a Go pkg pattern.                    |
| `test_workdir`       | Optional. Run `go test` inside this directory (collector-contrib has a per-subdir module layout). |
| `submodule_tag_paths`| Optional. Each path gets a `<path>/<tag>` reference (needed for Go submodule resolution in monorepos). |

## Secrets

`FORKS_PAT` (repository secret) — a `tsouza` PAT scoped to `repo` +
`workflow`. Required scopes:

- `repo` — push to fork branches, push tags, read repo state.
- `workflow` — push to `.github/workflows/` on the forks if needed.

The workflow logs the PAT in via `gh auth login --with-token` and via
`git config --global url.X.insteadOf` so both `gh` and `git` use it for
the entire run.

## Manual operations

### Force a re-check now

```bash
gh -R tsouza/cerberus-forks-monitor workflow run daily.yml
```

### Re-tag a fork after a manual rebase

```bash
# inside the fork checkout
LAST=$(git describe --tags --abbrev=0 --match 'v*-cerberus-*')
NEXT=$(echo "$LAST" | awk -F- '{...}')   # bump patch by hand
git tag "$NEXT"
git push origin "$NEXT"
```

### Add a new upstream

1. Fork the repo to `tsouza/<name>`.
2. Create a `cerberus-*` branch off the upstream commit you want as
   baseline. Push it. Set as default branch via
   `gh repo edit tsouza/<name> --default-branch cerberus-<flavor>`.
3. Tag the branch head as `v0.0.1-cerberus-<flavor>`.
4. Add a `.github/workflows/cerberus-branch-check.yml` to the fork to
   run subtree tests on every push.
5. Add an entry to [`monitor.yml`](monitor.yml).
6. Add the fork to `.github/dependabot.yml` in cerberus.
7. Add a `replace` directive in cerberus's `go.mod`.

## Watched repos

| Upstream                                              | Fork                                                  | Branch              | Tag prefix |
| ----------------------------------------------------- | ----------------------------------------------------- | ------------------- | ---------- |
| `prometheus/prometheus`                               | [`tsouza/prometheus`](https://github.com/tsouza/prometheus) | `cerberus-parser`   | `v0`       |
| `grafana/loki`                                        | [`tsouza/loki`](https://github.com/tsouza/loki)             | `cerberus-parser`   | `v3`       |
| `grafana/tempo`                                       | [`tsouza/tempo`](https://github.com/tsouza/tempo)           | `cerberus-accessors`| `v0`       |
| `open-telemetry/opentelemetry-collector-contrib`      | [`tsouza/opentelemetry-collector-contrib`](https://github.com/tsouza/opentelemetry-collector-contrib) | `cerberus-ddl`      | `v0`       |
