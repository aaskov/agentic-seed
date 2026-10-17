#!/usr/bin/env bash
# Generate a project from the template. Then run its gate in its devcontainer.
#
# Overrides:
#   COPIER       copier command (default: uvx copier@9.19.1)
#   KEEP=1       keep the generated project and its container
set -euo pipefail

seed="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read -r -a copier <<<"${COPIER:-uvx copier@9.19.1}"
tmp="$(mktemp -d)"
project="$tmp/demo-app"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    echo "test_template: kept $project"
    return
  fi
  docker ps -aq --filter "label=devcontainer.local_folder=$project" | xargs -r docker rm -f >/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "test_template: FAIL: $*" >&2
  exit 1
}

echo "== Generate"
"${copier[@]}" copy --defaults --quiet --vcs-ref HEAD \
  --data project_name=demo-app --data github_owner=demo-owner \
  "$seed" "$project"

echo "== Files"
[ -L "$project/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink."
[ "$(readlink "$project/CLAUDE.md")" = AGENTS.md ] || fail "CLAUDE.md does not link to AGENTS.md."
grep -q '^/contracts/ *@demo-owner$' "$project/.github/CODEOWNERS" || fail "CODEOWNERS has no owner."
grep -q '^# demo-app$' "$project/README.md" || fail "README.md has no project name."
grep -q '^_src_path:' "$project/.copier-answers.yml" || fail ".copier-answers.yml is missing."
[ -x "$project/.mise/tasks/check/rules" ] || fail "Task files are not executable."
if find "$project" -name '*.jinja' | grep -q .; then
  fail "A .jinja file was copied without rendering."
fi
if [ -e "$project/copier.yml" ] || [ -e "$project/tests/test_template.sh" ]; then
  fail "A file from outside template/ was copied."
fi
echo "  ok"

echo "== Gate in the devcontainer"
git -C "$project" init -q -b main
git -C "$project" add -A
git -C "$project" -c user.name=seed -c user.email=seed@example.invalid \
  -c commit.gpgsign=false commit -q -m "Generate from agentic-seed"
devcontainer up --workspace-folder "$project" >"$tmp/up.log" 2>&1 ||
  { tail -n 40 "$tmp/up.log" >&2; fail "devcontainer up failed."; }
# Use the same SEED_* variables as the CI workflow of a generated project.
devcontainer exec --workspace-folder "$project" \
  --remote-env SEED_BRANCH=main --remote-env SEED_BASE_REF=origin/main \
  mise run check ||
  fail "The gate failed in the generated project."

echo "test_template: ok"
