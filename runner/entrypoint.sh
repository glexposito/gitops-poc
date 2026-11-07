#!/usr/bin/env bash
# Registers this container as a repo-scoped self-hosted runner (first start
# only), then runs it.
#
# Registration uses RUNNER_TOKEN, a one-hour registration token - not a PAT.
# The runner's own credentials it gets back are saved in the
# github-runner-state volume, so later starts (restarts, recreated
# containers, rebuilt images) need no token at all. Only an empty volume
# (new machine, `docker compose down -v`) needs a fresh RUNNER_TOKEN.
set -euo pipefail

STATE=/runner-state
FILES=(.runner .credentials .credentials_rsaparams)

if [ -f "$STATE/.runner" ]; then
  for f in "${FILES[@]}"; do [ -f "$STATE/$f" ] && cp "$STATE/$f" .; done
else
  if [ -z "${RUNNER_TOKEN:-}" ]; then
    # Exit cleanly (restart: on-failure won't loop) so a plain
    # `docker compose up -d` works on a machine that isn't set up for CI.
    echo "github-runner not registered: set RUNNER_TOKEN in .env (see .env.example)"
    exit 0
  fi
  : "${RUNNER_REPO:?set RUNNER_REPO in .env (owner/repo)}"

  ./config.sh --unattended --replace \
    --url "https://github.com/$RUNNER_REPO" \
    --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-$(hostname)}" \
    --labels "${RUNNER_LABELS:-}"

  for f in "${FILES[@]}"; do [ -f "$f" ] && cp "$f" "$STATE/"; done
  echo "Registered - RUNNER_TOKEN is no longer needed, you can clear it from .env"
fi

# Jobs inherit this process's environment - don't hand them the token.
unset RUNNER_TOKEN
exec ./run.sh
