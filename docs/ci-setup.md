# CI setup: pulse-api → this repo's clusters

How [pulse-api](https://github.com/glexposito/pulse-api)'s pipeline deploys
into the local clusters, every credential it uses, and how to set them up,
on this machine or a new one.

## How it fits together

```
 GitHub (cloud)                                 Your machine (docker compose)
 ─────────────────────────────                 ──────────────────────────────────────
 pulse-api push to main
   └─ Build (ubuntu-latest)
        image → ghcr.io/glexposito/pulse-api@sha256:…
   └─ Internal / Stg / Prod deploy  ◄── polls ──  github-runner  (outbound only)
        runs-on: [self-hosted, local-k8s]           │
                                                    ├─ 1. pin digest in this repo
 glexposito/k8s-keda-poc  ◄──── git push (SSH) ─────┤      apps/pulse-api/overlays/<stage>
   └─ read by Argo CD  ◄──────────── polls ─────────┤
                                                    ├─ 2. argocd app sync → k3s-management:30090
                                                    └─ 3. e2e → http://k3s-<stage>:30080
```

Nothing on your machine is exposed. The runner and Argo CD both connect
**out** to GitHub, so GitHub never has to reach in. Each stage only starts
if the previous stage's e2e passed.

## Credentials

There are no PATs. Two credentials, each scoped to one job:

| Credential | What it allows | Where it lives | Expires |
|---|---|---|---|
| **Deploy key** "pulse-api pipeline" | Push to `glexposito/k8s-keda-poc` only | Public half: k8s-keda-poc → Settings → Deploy keys. Private half: pulse-api secret `GITOPS_SSH_KEY` | Never (revoke by deleting it) |
| **Runner credentials** | This machine running pulse-api's jobs | `github-runner-state` Docker volume | Never (revoke by removing the runner) |

Two other values aren't credentials you manage:

| Value | Notes |
|---|---|
| `RUNNER_TOKEN` in `.env` | One-hour registration token, only used on the runner's first start. Clear it afterwards. |
| `ARGOCD_PASSWORD` in `docker-compose.yaml` | The PoC's fixed `admin` / `123` login (see `argocd/helmchart.yaml`). Not secret. |

Why not something simpler:
- **The built-in `GITHUB_TOKEN`** can only write to the repo the workflow
  runs in. Pushing to this repo from pulse-api's pipeline fails with a 403,
  even though the same user owns both repos.
- **A PAT** is tied to your whole account and needs rotating. A deploy key
  is tied to one repo.
- **Actions OIDC** only authenticates to services outside GitHub (AWS,
  Azure, Vault…). GitHub's own API doesn't accept those tokens.

## One-time setup

You need `gh` logged in (`gh auth login`) as an admin of both repos, and
Docker. Commands are bash. Where fish differs, it's noted.

### 1. Protect pulse-api from fork PRs

pulse-api is public, and its deploy jobs run on your machine. Require
approval before any outside contributor's workflow runs:

```bash
gh api -X PUT repos/glexposito/pulse-api/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
```

(Or make the repo private: `gh repo edit glexposito/pulse-api --visibility private --accept-visibility-change-consequences`.)

### 2. Deploy key, so the pipeline can push to this repo

```bash
d=$(mktemp -d)                 # fish: set d (mktemp -d)
ssh-keygen -q -t ed25519 -N "" -f "$d/gitops_key" -C "pulse-api pipeline"
gh repo deploy-key add "$d/gitops_key.pub" -R glexposito/k8s-keda-poc --allow-write -t "pulse-api pipeline"
gh secret set GITOPS_SSH_KEY -R glexposito/pulse-api < "$d/gitops_key"
rm -rf "$d"
```

Check:

```bash
gh repo deploy-key list -R glexposito/k8s-keda-poc   # pulse-api pipeline  read-write
gh secret list -R glexposito/pulse-api               # GITOPS_SSH_KEY
```

### 3. The runner (repeat on every machine)

```bash
cd k8s-keda-poc
cp .env.example .env
gh api -X POST repos/glexposito/pulse-api/actions/runners/registration-token --jq .token
# paste the output after RUNNER_TOKEN= in .env (valid for 1 hour)
docker compose up -d --build
docker logs -f github-runner     # "Registered…", then "Listening for Jobs"
```

Without `gh`, the token is also shown at pulse-api → Settings → Actions →
Runners → New self-hosted runner.

Once it says "Registered", clear `RUNNER_TOKEN` in `.env`. The runner's
own credentials are now in the `github-runner-state` volume. Check:

```bash
gh api repos/glexposito/pulse-api/actions/runners --jq '.runners[] | [.name, .status] | @tsv'
# local-k8s-keda-poc   online
```

## Day to day

| You do | Token needed? |
|---|---|
| `docker compose stop` / `start` / `restart`, reboot | No |
| `docker compose down` then `up -d` | No (the volume survives) |
| `docker compose up -d --build` (rebuild the runner image) | No |
| `docker compose down -v` (wipes volumes) | **Yes**: redo step 3 |
| New machine | **Yes**: step 3 only. Steps 1–2 are per repo, not per machine. |

Running the pipeline:

```bash
gh workflow run pipeline.yml -R glexposito/pulse-api   # or push to pulse-api main
gh run watch -R glexposito/pulse-api
gh run rerun <run-id> -R glexposito/pulse-api --failed # after fixing a failure
```

## Revoking and rotating

```bash
# Deploy key: delete it, then redo step 2 for a new one
gh repo deploy-key list   -R glexposito/k8s-keda-poc
gh repo deploy-key delete <id> -R glexposito/k8s-keda-poc

# Runner: remove it from GitHub, wipe its saved registration, redo step 3
gh api repos/glexposito/pulse-api/actions/runners --jq '.runners[] | [.id, .name] | @tsv'
gh api -X DELETE repos/glexposito/pulse-api/actions/runners/<id>
docker compose rm -sf github-runner && docker volume rm k8s-keda-poc_github-runner-state
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Deploy job stuck in **Queued** | Runner offline. Check `docker ps -a --filter name=github-runner` and `docker logs github-runner`. Queued jobs expire after 24 h. |
| Runner log: `github-runner not registered: set RUNNER_TOKEN` | First start without a token, or the volume was wiped. Do step 3. |
| Runner log: registration fails / `401` | The token is older than 1 hour. Get a new one. |
| Runner keeps restarting after you removed it on GitHub | Its saved registration is stale. Wipe the volume (see Revoking) and redo step 3. |
| **Pin image digest**: `403 … denied to github-actions[bot]` | `GITOPS_SSH_KEY` is missing, so the checkout fell back to `GITHUB_TOKEN`. Do step 2. |
| **Checkout GitOps repo**: `Input required and not supplied: token` | An old run, from before the deploy-key switch. Run the pipeline again. |
| **Sync with Argo CD**: app not found | The ApplicationSet isn't in Argo CD yet. Check this repo is pushed and `argocd-bootstrap` finished. |
| **E2E**: connection refused | Pods not ready. Check `docker exec k3s-<stage> kubectl -n pulse-api get pods,svc`. |
