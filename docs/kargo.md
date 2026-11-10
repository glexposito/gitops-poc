# Kargo (promotion, the controller way)

The second promotion path, next to pulse-api's CI pipeline
([ci-setup.md](ci-setup.md)). Both promote the same builds through
internal → stg → prod, into separate copies of the app, so they can be
compared side by side:

|                   | CI path                                 | Kargo path                                     |
| ----------------- | --------------------------------------- | ---------------------------------------------- |
| Driven by         | GitHub Actions (`deploy.yml`) on the self-hosted runner | Kargo on the management cluster     |
| Overlays          | `apps/pulse-api/overlays/<stage>`       | `apps/pulse-api-kargo/overlays/<stage>`        |
| Argo CD apps      | `pulse-api-<stage>`                     | `pulse-api-kargo-<stage>`                      |
| Namespace / port  | `pulse-api`, `:30080` (host 8081-8083)  | `pulse-api-kargo`, `:30081` (host 8091-8093)   |
| E2E               | `scripts/e2e.sh` on the runner          | The build's `pulse-api-e2e` image, as a Job    |
| Prod gate         | Automatic once stg passes               | Manual: Promote in the Kargo UI                |

Kargo UI: **https://localhost:9001** (`admin` / `123`).

## How it works

```
pulse-api push → pipeline.yml pushes pulse-api:sha-abc1234 + pulse-api-e2e:sha-abc1234
                      │
Warehouse (polls GHCR) → Freight = that matching pair
                      │
Stage internal ── promote → verify ──▶ Stage stg ── promote → verify ──▶ Stage prod (manual)
```

| File (`kargo/pulse-api/`) | What                                                          |
| ------------------------- | ------------------------------------------------------------- |
| `project.yaml`            | Kargo Project + which Stages auto-promote (internal, stg)     |
| `warehouse.yaml`          | Subscribes to both images; Freight only when their tags match |
| `promotion-task.yaml`     | The steps: clone, `kustomize-set-image`, commit, push, `argocd-update` |
| `stages.yaml`             | internal ← Warehouse, stg ← internal, prod ← stg              |
| `e2e.yaml`                | AnalysisTemplate: runs the e2e image as a Job; exit 0 = verified |

Kargo, cert-manager and Argo Rollouts are installed by Argo CD
(`argocd/kargo/install.yaml`), not by Compose. Only Rollouts' analysis
controller is used, for verification. pulse-api stays a plain Deployment.

## Setup (once)

Kargo pushes to this repo with its own deploy key, separate from the CI
pipeline's.

```bash
cd cluster
ssh-keygen -q -t ed25519 -N "" -f secrets/kargo-git-key -C "kargo"
gh repo deploy-key add secrets/kargo-git-key.pub -R glexposito/gitops-poc --allow-write -t "kargo"
rm secrets/kargo-git-key.pub
docker compose up -d --force-recreate argocd-bootstrap   # puts the key in the cluster
```

`cluster/secrets/` is gitignored (apart from `.gitkeep`).

## Try it

1. Push to pulse-api `main`. Within a few minutes a new Freight appears in
   the Kargo UI and goes through internal and stg on its own.
2. Promote it to prod in the UI.
3. Each promotion is a `pulse-api-kargo: promote sha-… to <stage>` commit here.

```bash
# What's running where
docker exec k3s-management kubectl -n pulse-api get freight,stages
# E2E logs of the latest verification
docker exec k3s-management kubectl -n pulse-api get jobs
docker exec k3s-management kubectl -n pulse-api logs job/<name>
# The Kargo copy on prod (CI copy: 8083)
curl localhost:8093/hostname
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No Freight | Both images need a matching `sha-*` tag. Old builds have no `pulse-api-e2e` image, so push a new commit. `pulse-api-e2e` must be public on GHCR, or the Warehouse can't read it. |
| `kargo` app keeps retrying | Normal on a fresh cluster until cert-manager is up |
| Promotion fails at `git-push` | The key is missing: do the setup above. `docker exec k3s-management kubectl -n pulse-api get secret gitops-poc-git` |
| `argocd-update` not authorized | The Application needs `kargo.akuity.io/authorized-stage: pulse-api:<stage>` (`argocd/appsets/pulse-api-kargo.yaml`) |
| Verification fails | Read the Job's logs, same PASS/FAIL output as CI |

## Changing the e2e tests

The contract between Kargo and the tests is just "an image that takes the
base URL as its argument and exits 0 on success". Today `pulse-api-e2e`
wraps `scripts/e2e.sh`. Playwright or `dotnet test` would be a different
`Dockerfile.e2e` in pulse-api, with no change here except maybe more
memory in `e2e.yaml`.
