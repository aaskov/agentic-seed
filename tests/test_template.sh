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
# A rendered value must not change between runs, or each copier update conflicts.
if grep -rqs 'copier\._vcs\.clone' "$project"; then
  fail "A file holds the path of a temporary copier clone."
fi
grep -qx 'AGENT_BOT_APP_ID=' "$project/.devcontainer/agent-bot.env" || fail "The bot is not off by default."
[ -x "$project/.mise/tasks/check/rules" ] || fail "Task files are not executable."
if find "$project" -name '*.jinja' | grep -q .; then
  fail "A .jinja file was copied without rendering."
fi
if [ -e "$project/copier.yml" ] || [ -e "$project/tests/test_template.sh" ]; then
  fail "A file from outside template/ was copied."
fi
echo "  ok"

echo "== Gate in the devcontainer"
# Extension point: setup runs each executable in .mise/setup.d/ (a stack uses it).
printf '#!/usr/bin/env bash\ntouch .setup-d-ran\n' >"$project/.mise/setup.d/50-test-marker"
chmod +x "$project/.mise/setup.d/50-test-marker"
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

[ -e "$project/.setup-d-ran" ] || fail "setup did not run the scripts in .mise/setup.d/."

# Extension point: check:guardrails runs each tests/guardrails/test_*.sh (a stack adds one).
printf '#!/usr/bin/env bash\necho "extra: seeded failure"\nexit 1\n' >"$project/tests/guardrails/test_extra.sh"
chmod +x "$project/tests/guardrails/test_extra.sh"
if devcontainer exec --workspace-folder "$project" mise run check:guardrails >"$tmp/extra.log" 2>&1; then
  fail "check:guardrails did not run tests/guardrails/test_extra.sh."
fi
grep -q "extra: seeded failure" "$tmp/extra.log" || fail "check:guardrails did not show the output of test_extra.sh."
rm "$project/tests/guardrails/test_extra.sh"

devcontainer exec --workspace-folder "$project" git config --global --get credential.https://github.com.helper &&
  fail "The bot is off, but git uses the bot credential helper."

echo "test_template: ok"
