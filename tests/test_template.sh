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
for f in .mise/tasks/agent/start .mise/tasks/agent/finish .devcontainer/claude-auth.sh; do
  [ -x "$project/$f" ] || fail "$f is missing or not executable."
done
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
# A pinned tool must be on PATH for a plain shell in the container, as an agent uses it.
# It is in mise.container.toml, so host mise must not see it.
sed -i.bak 's/^\[tools\]$/[tools]\njq = "1.7.1"/' "$project/mise.container.toml" && rm "$project/mise.container.toml.bak"
if command -v mise >/dev/null; then
  host_tools="$(cd "$project" && MISE_ENV= MISE_TRUSTED_CONFIG_PATHS="$project" mise ls --current --no-header 2>/dev/null | awk '{print $1}')"
  if grep -qx jq <<<"$host_tools"; then
    fail "Host mise sees a container tool (jq). Container tools must stay in mise.container.toml."
  fi
fi
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

# A plain, non-login shell (as an agent uses) must find the pinned tool version.
jq_version="$(devcontainer exec --workspace-folder "$project" bash -c 'jq --version' 2>/dev/null)"
[ "$jq_version" = "jq-1.7.1" ] || fail "A plain shell does not use the pinned jq. It got '$jq_version'."

[ -e "$project/.setup-d-ran" ] || fail "setup did not run the scripts in .mise/setup.d/."

# Extension point: check:guardrails runs each tests/guardrails/test_*.sh (a stack adds one).
printf '#!/usr/bin/env bash\necho "extra: seeded failure"\nexit 1\n' >"$project/tests/guardrails/test_extra.sh"
chmod +x "$project/tests/guardrails/test_extra.sh"
if devcontainer exec --workspace-folder "$project" mise run check:guardrails >"$tmp/extra.log" 2>&1; then
  fail "check:guardrails did not run tests/guardrails/test_extra.sh."
fi
grep -q "extra: seeded failure" "$tmp/extra.log" || fail "check:guardrails did not show the output of test_extra.sh."
rm "$project/tests/guardrails/test_extra.sh"

# The agent tasks refuse bad input before they change anything (docs/adr/0006).
(cd "$project" && .mise/tasks/agent/start >/dev/null 2>&1) && fail "agent:start runs without an issue."
(cd "$project" && .mise/tasks/agent/finish 999999 >"$tmp/finish.log" 2>&1) && fail "agent:finish runs for a clone that does not exist."
grep -q "demo-app-agent-999999 does not exist" "$tmp/finish.log" || fail "agent:finish did not report the missing clone."

# Agents use Sonnet by default. AGENT_MODEL overrides it (docs/adr/0006).
grep -q 'model="${AGENT_MODEL:-claude-sonnet-5-5}"' "$project/.mise/tasks/agent/start" ||
  fail "agent:start does not default to claude-sonnet-5-5 with an AGENT_MODEL override."
grep -q 'claude --model "$model"' "$project/.mise/tasks/agent/start" ||
  fail "agent:start does not pass the model to claude."
# Agents run in auto mode by default. AGENT_PERMISSION_MODE overrides it (docs/adr/0006).
grep -q 'mode="${AGENT_PERMISSION_MODE:-auto}"' "$project/.mise/tasks/agent/start" ||
  fail "agent:start does not default to auto mode with an AGENT_PERMISSION_MODE override."
grep -q -- '--permission-mode "$mode"' "$project/.mise/tasks/agent/start" ||
  fail "agent:start does not pass the permission mode to claude."

# The Claude wrapper is in front of claude. It reports on (a token on the host) or off.
grep -Eq "claude-auth: (on|off)\." "$tmp/up.log" || fail "post-create did not run claude-auth.sh."
devcontainer exec --workspace-folder "$project" bash -c '[ "$(command -v claude)" = /usr/local/bin/claude ]' ||
  fail "claude in the container is not the token wrapper."

devcontainer exec --workspace-folder "$project" git config --global --get credential.https://github.com.helper &&
  fail "The bot is off, but git uses the bot credential helper."

echo "test_template: ok"
