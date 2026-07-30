#!/usr/bin/env bash
#
# cerberus-forks-monitor — daily sync worker.
#
# For each entry in monitor.yml:
#   1. Clone upstream + fork.
#   2. Look at commits in upstream/main since the last cerberus tag on
#      fork_branch. If none of those commits touched relevant_paths,
#      skip silently.
#   3. Otherwise rebase fork_branch onto upstream/main, run the configured
#      test subtrees, and on success push + tag (bumping the patch).
#   4. On failure (rebase conflict or test red) open an issue in this
#      repo, skip the dep for today, and mark the overall run failed
#      (the remaining deps are still processed).
#
# Dependencies: bash 5+, git, gh, yq, jq, go.

set -euo pipefail

CONFIG="${MONITOR_CONFIG:-monitor.yml}"
WORK_ROOT="$(mktemp -d -t cerberus-forks-monitor-XXXXXX)"
MONITOR_REPO="${MONITOR_REPO:-tsouza/cerberus-forks-monitor}"

if [[ ! -f "${CONFIG}" ]]; then
  echo "monitor.yml not found at ${CONFIG}" >&2
  exit 1
fi

if ! command -v yq >/dev/null; then
  echo "yq not installed; aborting" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

# Bump the patch component of a semver-ish tag. Preserves the cerberus
# pre-release suffix.
#  v0.0.1-cerberus-parser  -> v0.0.2-cerberus-parser
#  v3.0.7-cerberus-parser  -> v3.0.8-cerberus-parser
bump_patch() {
  local tag="$1"
  local body="${tag#v}"
  local suffix=""
  if [[ "${body}" == *-* ]]; then
    suffix="-${body#*-}"
    body="${body%%-*}"
  fi
  local major minor patch
  IFS=. read -r major minor patch <<<"${body}"
  patch=$((patch + 1))
  printf 'v%s.%s.%s%s\n' "${major}" "${minor}" "${patch}" "${suffix}"
}

# Reads a list-valued dep field into the named array.
#
# `mapfile -t arr < <(yq ...)` discards yq's exit status, so a config typo or
# an expression this yq build rejects yields an EMPTY ARRAY that reads exactly
# like a legitimately absent optional field. That is how
# `.submodule_tag_paths[]? // empty` — `empty` is a jq builtin, not a yq one —
# silently disabled every per-submodule tag: the expression errored on every
# dep, every day, and the loop over the empty array minted nothing. Capturing
# the output first makes the failure abort the dep instead.
#
# An absent optional field is NOT an error: yq exits 0 and prints nothing, so
# it is normalised to an empty array here.
yq_list() {
  local -n __dest="$1"
  local name="$2" field="$3" raw
  if ! raw="$(yq -r ".deps[] | select(.name == \"${name}\") | .${field}[]" "${CONFIG}" 2>&1)"; then
    log "    reading .${field} for ${name} failed: ${raw}"
    return 1
  fi
  if [[ -z "${raw}" ]]; then
    __dest=()
  else
    mapfile -t __dest <<<"${raw}"
  fi
}

# Opens a failure-report issue. Returns nonzero (and logs) if issue
# creation itself fails so the caller can surface that too — issue
# creation failing must not hide the underlying dep failure.
open_issue() {
  local title="$1"
  local body="$2"
  if ! gh -R "${MONITOR_REPO}" issue create \
    --title "${title}" \
    --body "${body}" \
    --label "monitor-failure" >/dev/null; then
    log "    FAILED to open issue: ${title}"
    return 1
  fi
}

process_dep() {
  local name="$1"
  local upstream fork fork_branch tag_prefix
  upstream="$(yq -r ".deps[] | select(.name == \"${name}\") | .upstream" "${CONFIG}")"
  fork="$(yq -r ".deps[] | select(.name == \"${name}\") | .fork" "${CONFIG}")"
  fork_branch="$(yq -r ".deps[] | select(.name == \"${name}\") | .fork_branch" "${CONFIG}")"
  tag_prefix="$(yq -r ".deps[] | select(.name == \"${name}\") | .tag_prefix" "${CONFIG}")"
  local test_workdir
  test_workdir="$(yq -r ".deps[] | select(.name == \"${name}\") | .test_workdir // \"\"" "${CONFIG}")"

  # Every field above is mandatory; yq prints the string `null` for a key that
  # is absent, so an entry missing one would otherwise run against a remote
  # literally named "null".
  local field
  for field in upstream fork fork_branch tag_prefix; do
    if [[ -z "${!field}" || "${!field}" == "null" ]]; then
      log "==> ${name}: config is missing .${field}"
      return 1
    fi
  done

  local relevant_paths test_subtrees submodule_tag_paths
  yq_list relevant_paths "${name}" relevant_paths || return 1
  yq_list test_subtrees "${name}" test_subtrees || return 1
  yq_list submodule_tag_paths "${name}" submodule_tag_paths || return 1

  # Both lists are mandatory, and an empty one is worse than a missing dep:
  # `git log -- ` with no pathspec matches EVERY upstream commit, so the monitor
  # would rebase and tag on every unrelated change — the exact Dependabot noise
  # this repo exists to suppress. An empty test_subtrees skips the test gate
  # entirely and force-pushes an unvalidated rebase. Only submodule_tag_paths is
  # legitimately optional (single-module forks have none).
  if (( ${#relevant_paths[@]} == 0 )); then
    log "==> ${name}: .relevant_paths is empty; refusing to treat every upstream commit as relevant"
    return 1
  fi
  if (( ${#test_subtrees[@]} == 0 )); then
    log "==> ${name}: .test_subtrees is empty; refusing to push an untested rebase"
    return 1
  fi

  log "==> ${name}: upstream=${upstream} fork=${fork} branch=${fork_branch}"

  # NOTE: main() calls this function as an `if` condition, which makes
  # bash ignore `set -e` inside the function body — every command that
  # must abort the dep on failure needs an explicit guard.
  local work="${WORK_ROOT}/${name}"
  if ! git clone --quiet "https://github.com/${fork}.git" "${work}"; then
    log "    clone of ${fork} failed"
    return 1
  fi
  pushd "${work}" >/dev/null

  if ! git remote add upstream "https://github.com/${upstream}.git" ||
     ! git fetch --quiet --tags upstream "+refs/heads/main:refs/remotes/upstream/main" ||
     ! git fetch --quiet --tags origin; then
    log "    fetching ${upstream} / ${fork} failed"
    popd >/dev/null
    return 1
  fi

  # Find the last cerberus tag on fork_branch. Falls back to the branch root
  # commit if no tag exists yet.
  local last_tag
  last_tag="$(git describe --tags --abbrev=0 --match "${tag_prefix}.*-cerberus-*" "origin/${fork_branch}" 2>/dev/null || true)"
  if [[ -z "${last_tag}" ]]; then
    log "    no cerberus tag found on ${fork_branch}; cannot proceed safely"
    open_issue "[${name}] no baseline cerberus tag" "Run an initial tag mint on \`${fork}\` before the monitor can take over." || true
    popd >/dev/null
    return 1
  fi
  log "    last tag: ${last_tag}"

  # Did anything in relevant_paths change in upstream since last tag?
  local changed
  changed="$(git log --pretty=format:%H "${last_tag}..upstream/main" -- "${relevant_paths[@]}" || true)"
  if [[ -z "${changed}" ]]; then
    log "    no relevant changes since ${last_tag}; skipping"
    popd >/dev/null
    return 0
  fi
  log "    relevant commits: $(echo "${changed}" | wc -l)"

  if ! git checkout --quiet "${fork_branch}"; then
    log "    checkout of ${fork_branch} failed"
    popd >/dev/null
    return 1
  fi
  if ! git rebase upstream/main; then
    log "    rebase conflict; opening issue"
    local conflict
    conflict="$(git status --short || true)"
    git rebase --abort || true
    open_issue \
      "[${name}] rebase conflict on $(date -u +%Y-%m-%d)" \
      "Rebasing \`${fork_branch}\` onto \`upstream/main\` produced conflicts. Conflict status:\\n\\n\`\`\`\\n${conflict}\\n\`\`\`\\n\\nManual rebase required. After fixing locally and force-pushing, re-run the workflow." || true
    popd >/dev/null
    return 1
  fi

  # Run subtree tests.
  local test_status=0
  if [[ -n "${test_workdir}" ]]; then
    if ! pushd "${test_workdir}" >/dev/null; then
      log "    test_workdir ${test_workdir} does not exist after rebase"
      popd >/dev/null
      return 1
    fi
  fi
  log "    running tests: ${test_subtrees[*]}"
  if ! go test -count=1 "${test_subtrees[@]}"; then
    test_status=1
  fi
  if [[ -n "${test_workdir}" ]]; then
    popd >/dev/null
  fi
  if (( test_status != 0 )); then
    log "    tests red after rebase; opening issue"
    open_issue \
      "[${name}] tests fail after rebase on $(date -u +%Y-%m-%d)" \
      "Rebasing \`${fork_branch}\` onto \`upstream/main\` succeeded, but \`go test\` on the cerberus subtree failed. The branch was NOT force-pushed. Reproduce with: \`git clone https://github.com/${fork}.git && cd $(basename "${fork}") && git fetch origin && git checkout ${fork_branch} && git fetch https://github.com/${upstream}.git main && git rebase FETCH_HEAD\`." || true
    popd >/dev/null
    return 1
  fi

  # Tests green — push the rebased branch.
  log "    pushing rebased branch"
  if ! git push --force-with-lease origin "${fork_branch}"; then
    log "    push of ${fork_branch} failed"
    popd >/dev/null
    return 1
  fi

  # Mint new tag.
  local new_tag
  new_tag="$(bump_patch "${last_tag}")"
  log "    minting tag ${new_tag}"
  if ! git tag "${new_tag}" || ! git push origin "${new_tag}"; then
    log "    minting/pushing tag ${new_tag} failed"
    popd >/dev/null
    return 1
  fi

  # Per-submodule tags (collector-contrib style).
  for sub in "${submodule_tag_paths[@]}"; do
    local sub_tag="${sub}/${new_tag}"
    if ! git tag "${sub_tag}" || ! git push origin "${sub_tag}"; then
      log "    minting/pushing submodule tag ${sub_tag} failed"
      popd >/dev/null
      return 1
    fi
    log "    minting submodule tag ${sub_tag}"
  done

  popd >/dev/null
}

main() {
  local names
  mapfile -t names < <(yq -r '.deps[].name' "${CONFIG}")
  log "monitor run start (deps: ${names[*]})"
  local failures=0
  local failed_deps=()
  for dep in "${names[@]}"; do
    if ! process_dep "${dep}"; then
      failures=$((failures + 1))
      failed_deps+=("${dep}")
    fi
  done
  if (( failures > 0 )); then
    log "monitor run FAILED for ${failures} dep(s): ${failed_deps[*]}"
    exit 1
  fi
  log "monitor run complete"
}

main "$@"
