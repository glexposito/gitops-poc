# Promotion with Kargo

Kargo promotes pulse-api through internal → stg → prod. Each environment runs
**one** pulse-api (`pulse-api-<stage>`, namespace `pulse-api`, port 30080).
Kargo deploys a build there, then runs that build's Playwright tests against
**that deployment**, and only a build that passed may move to the next stage.

Kargo UI: **https://localhost:9001** (`admin` / `123`).

## How it works

```
pulse-api push → GitHub Actions builds + pushes
                   pulse-api:sha-abc1234       (the app)
                   pulse-api-e2e:sha-abc1234   (its Playwright tests)
                      │
Warehouse (polls GHCR every 5m) → Freight = that matching pair
                      │
Stage internal: deploy pulse-api-internal → run tests against http://k3s-internal:30080 → pass
                      │
Stage stg:      deploy pulse-api-stg      → run tests against http://k3s-stg:30080      → pass
                      │
Stage prod:     waits for Promote in the UI → deploy → run tests against http://k3s-prod:30080
```

"Deploy" is: commit the new digest to `apps/pulse-api/overlays/<stage>`, push,
and sync the Argo CD app to exactly that commit. The tests run as a Job on
management (Argo Rollouts' analysis); exit 0 marks the build verified in that
stage. Nothing else is deployed for testing.

Kargo, cert-manager and Argo Rollouts are installed by Argo CD
(`argocd/kargo/install.yaml`), not by Compose. Only Rollouts' analysis
controller is used. pulse-api stays a plain Deployment.

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
| `appsets/kargo-apps-workloads.yaml` | `<app>-<stage>`: every app file × every workload cluster, with the `authorized-stage` annotation Kargo needs |

The git credential is shared too: it lives in `kargo-shared-resources`,
which every Kargo Project falls back to.

## Adding an app

1. Its manifests: `apps/<app>/base` + `overlays/<stage>`.
2. Its namespace on each cluster: `manifests/<cluster>/`, and an AppProject
   that allows it.
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

pulse-api's tests are in pulse-api's `e2e/`. Results are in the Job's logs.
There's no artifact storage, so Playwright's HTML reports and traces aren't
kept.

## Setup (once)

1. Kargo pushes promotions to this repo with a deploy key:

   ```bash
   cd cluster
   ssh-keygen -q -t ed25519 -N "" -f secrets/kargo-git-key -C "kargo"
   gh repo deploy-key add secrets/kargo-git-key.pub -R glexposito/gitops-poc --allow-write -t "kargo"
   rm secrets/kargo-git-key.pub
   docker compose up -d --force-recreate argocd-bootstrap   # puts the key in the cluster
   ```

   `cluster/secrets/` is gitignored (apart from `.gitkeep`).

2. The Warehouse reads GHCR without credentials, so both images must be
   public: GitHub → Packages → `pulse-api-e2e` → Package settings → Change
   visibility → Public (once; `pulse-api` already is).

## Try it

1. Push to pulse-api `main`. Within a few minutes a new Freight appears in
   the Kargo UI and goes through internal and stg on its own.
2. Promote it to prod in the UI.
3. Each promotion is a `pulse-api: promote sha-… to <stage>` commit here.

On a fresh cluster the `pulse-api-*` apps show Missing/OutOfSync until their
first promotion: auto-sync is off, so only Kargo deploys them.

```bash
# What's running where
docker exec k3s-management kubectl -n pulse-api get freight,stages
# E2E logs of the latest verification
docker exec k3s-management kubectl -n pulse-api get jobs
docker exec k3s-management kubectl -n pulse-api logs job/<name>
# pulse-api on prod
curl localhost:8083/hostname
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No Freight | Both images need a matching `sha-*` tag, and `pulse-api-e2e` must be public on GHCR |
| `kargo` app keeps retrying | Normal on a fresh cluster until cert-manager is up |
| `kargo-shared` / `kargo-<project>` retrying | Normal until Kargo's and Rollouts' CRDs exist |
| Promotion fails at `git-push` | The key is missing: do setup step 1. `docker exec k3s-management kubectl -n kargo-shared-resources get secret gitops-poc-git` |
| `argocd-update` not authorized | The Application needs `kargo.akuity.io/authorized-stage: <project>:<stage>` (`argocd/appsets/kargo-apps-workloads.yaml`) |
| Verification fails | Read the Job's logs: Playwright's `list` output, one line per test |
| Playwright Job OOMKilled | Raise memory in `kargo/shared/e2e-playwright.yaml` |
