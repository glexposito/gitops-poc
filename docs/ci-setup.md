# CI setup (pulse-api)

## How it works

1. A push to pulse-api `main` builds the image on GitHub and pushes it to GHCR.
2. For each stage (internal → stg → prod), the self-hosted `github-runner`
   (a Compose service) does three things:
   1. Commits the new digest to `apps/pulse-api/overlays/<stage>` here.
   2. Runs `argocd app sync` and waits for Healthy.
   3. Runs e2e against `http://k3s-<stage>:30080`. A failure stops the
      promotion.

The runner only connects out to GitHub, so nothing on your machine is exposed.

## Credentials

There are no PATs, just two credentials:

| Credential | Allows | Lives in |
|---|---|---|
| Deploy key "pulse-api pipeline" | Pushing to this repo only | Public half: this repo's deploy keys. Private half: pulse-api secret `GITOPS_SSH_KEY` |
| Runner registration | This machine running pulse-api's jobs | The `github-runner-state` volume |

The deploy key is needed because the built-in `GITHUB_TOKEN` can't push to
another repo, even one you own.

## Setup

You need `gh` logged in as admin of both repos. In fish, write
`set d (mktemp -d)` instead of `d=$(mktemp -d)`.

**1. Protect pulse-api** (it's public, and its jobs run on your machine):

```bash
gh api -X PUT repos/glexposito/pulse-api/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
```

**2. Deploy key** (once per repo):

```bash
d=$(mktemp -d)
ssh-keygen -q -t ed25519 -N "" -f "$d/gitops_key" -C "pulse-api pipeline"
gh repo deploy-key add "$d/gitops_key.pub" -R glexposito/gitops-poc --allow-write -t "pulse-api pipeline"
gh secret set GITOPS_SSH_KEY -R glexposito/pulse-api < "$d/gitops_key"
rm -rf "$d"
```

**3. Runner** (once per machine):

```bash
cp .env.example .env
gh api -X POST repos/glexposito/pulse-api/actions/runners/registration-token --jq .token
# paste it after RUNNER_TOKEN= in .env (valid for 1 hour)
docker compose up -d --build
docker logs -f github-runner   # wait for "Listening for Jobs", then clear RUNNER_TOKEN
```

The registration survives restarts and `docker compose down`. Only
`down -v` or a new machine needs step 3 again.

## Run it

```bash
gh workflow run pipeline.yml -R glexposito/pulse-api   # or push to main
gh run watch -R glexposito/pulse-api
```

## Revoke

```bash
gh repo deploy-key delete <id> -R glexposito/gitops-poc        # ids: gh repo deploy-key list
gh api -X DELETE repos/glexposito/pulse-api/actions/runners/<id> # ids: …/actions/runners
docker compose rm -sf github-runner && docker volume rm gitops-poc_github-runner-state
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Deploy job stuck in Queued | Runner is down: `docker logs github-runner` |
| `not registered: set RUNNER_TOKEN` | Do setup step 3 |
| Registration fails with 401 | The token is over 1 hour old. Get a new one. |
| Pin image digest fails with 403 | `GITOPS_SSH_KEY` is missing. Do setup step 2. |
| Sync fails: app not found | Push this repo, and wait for `argocd-bootstrap` to finish |
| E2E: connection refused | `docker exec k3s-<stage> kubectl -n pulse-api get pods,svc` |
