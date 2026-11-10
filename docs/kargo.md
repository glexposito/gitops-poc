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
| E2E               | `scripts/e2e.sh` on the runner          | The build's Playwright image (`pulse-api-e2e`), as a Job |
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

Kargo, cert-manager and Argo Rollouts are installed by Argo CD
(`argocd/kargo/install.yaml`), not by Compose. Only Rollouts' analysis
controller is used, for verification. Apps stay plain Deployments.

## Layout: written once, one file per app

```
kargo/
  shared/                        # every app uses these, cluster-wide
    promote-kustomize-app.yaml   #   ClusterPromotionTask: set digest, commit, push, argocd-update
    e2e-basic.yaml               #   ClusterAnalysisTemplate: small pod (bash/curl tests)
    e2e-playwright.yaml          #   ClusterAnalysisTemplate: 1Gi+, /dev/shm, longer deadline
  chart/                         # renders one app's Project, Warehouse, Stages
  apps/
    pulse-api.yaml               # the only per-app Kargo config
```

| Argo CD (`argocd/`)                 | Creates                                                   |
| ----------------------------------- | --------------------------------------------------------- |
| `kargo/shared.yaml`                 | `kargo/shared/` on management                             |
| `kargo/apps.yaml`                   | `kargo-<project>`: one chart instance per app file        |
| `appsets/kargo-apps-workloads.yaml` | `<app>-<stage>`: every app file × every workload cluster, with the `authorized-stage` annotation |

The git credential is shared too: it lives in `kargo-shared-resources`,
which every Kargo Project falls back to.

## Adding an app

1. Its manifests: `apps/<app>/base` + `overlays/<stage>` (needed anyway).
2. Its namespace on each cluster: `manifests/<cluster>/` (needed anyway), and
   allow it in the app's AppProject.
3. Its CI pushes `<image>:sha-*` and `<image>-e2e:sha-*`.
4. `kargo/apps/<app>.yaml`:

```yaml
project: orders                      # Kargo Project (namespace on management)
app: orders-api                      # apps/<app>/, Argo CD apps <app>-<stage>, namespace
argocdProject: orders
image: ghcr.io/glexposito/orders-api
e2eImage: ghcr.io/glexposito/orders-api-e2e
port: 30082
verification: [e2e-basic]
```

Every option and default: `kargo/chart/values.yaml`.

## Choosing how an app is tested

How the tests run is the e2e image's business: its entrypoint takes the
base URL and exits 0 when everything passes. Bash, Playwright and `dotnet
test` are all just different images. What the app file picks is the pod
the image runs in:

```yaml
verification: [e2e-playwright]          # one list for every stage

verification:                           # or per stage - all listed must pass
  internal: [e2e-basic]
  stg: [e2e-basic, e2e-playwright]
  prod: [e2e-basic]                     # a stage left out isn't verified
```

A new kind of test (load tests, a Prometheus error-rate check) is a new
template in `kargo/shared/`. An app with a one-off need can have its own
AnalysisTemplate in its Project namespace instead.

pulse-api uses `e2e-playwright`: its tests are in pulse-api's `e2e/`. Results
are in the Job's logs. There's no artifact storage, so Playwright's HTML
reports and traces aren't kept.

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
| `kargo-shared` / `kargo-<project>` retrying | Normal until Kargo's and Rollouts' CRDs exist |
| Promotion fails at `git-push` | The key is missing: do the setup above. `docker exec k3s-management kubectl -n kargo-shared-resources get secret gitops-poc-git` |
| `argocd-update` not authorized | The Application needs `kargo.akuity.io/authorized-stage: <project>:<stage>` (`argocd/appsets/kargo-apps-workloads.yaml`) |
| Verification fails | Read the Job's logs: Playwright's `list` output, one line per test |
| Playwright Job OOMKilled | Raise memory in `kargo/shared/e2e-playwright.yaml` |
