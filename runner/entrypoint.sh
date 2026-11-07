#!/usr/bin/env bash
# Registers this container as a repo-scoped self-hosted runner, then runs it.
# Exchanges GITHUB_PAT (from .env) for a short-lived registration token, so
# there's no one-hour token to paste by hand.
set -euo pipefail

# A restarted container keeps its registration; only a new container
# registers again, replacing the old one by name.
if [ ! -f .runner ]; then
  if [ -z "${GITHUB_PAT:-}" ]; then
    # Exit cleanly (restart: on-failure won't loop) so a plain
    # `docker compose up -d` works on a machine without a PAT.
    echo "github-runner disabled: set GITHUB_PAT in .env (see .env.example)"
    exit 0
  fi
  : "${RUNNER_REPO:?set RUNNER_REPO in .env (owner/repo)}"

  token=$(curl -fsS -X POST \
    -H "Authorization: Bearer $GITHUB_PAT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$RUNNER_REPO/actions/runners/registration-token" | jq -r .token)

  ./config.sh --unattended --replace \
    --url "https://github.com/$RUNNER_REPO" \
    --token "$token" \
    --name "${RUNNER_NAME:-$(hostname)}" \
    --labels "${RUNNER_LABELS:-}"
fi

# Jobs inherit this process's environment - don't hand them the PAT.
unset GITHUB_PAT token
exec ./run.sh
