# Architecture

## Clusters and bootstrap

Four single-node k3s clusters in Docker (`cluster/docker-compose.yaml`):
**management** runs only the platform (Argo CD, and Kargo), and **internal / stg / prod** are the
workload clusters, one per promotion stage. Keeping Argo CD on its own
cluster means losing a workload cluster never takes down the thing that
manages it.

`cd cluster && docker compose up -d` does everything:

1. Each k3s container auto-applies its `manifests/<cluster>/`, which is
   bind-mounted in. On the workload clusters that includes the
   `argocd-manager` ServiceAccount Argo CD will use.
2. k3s installs Argo CD on management from `cluster/argocd-install.yaml`.
3. `cluster/bootstrap.sh` (the `argocd-bootstrap` service) registers
   internal/stg/prod with Argo CD, labelled `role=workload` and
   `stage=<cluster>`, then applies `argocd/root-app.yaml`. From then on,
   Argo CD manages everything from git.

`cluster/` is the stand-in for real cluster infrastructure, and Argo CD never
reads it. Everything Argo CD syncs lives in `argocd/`, `apps/` and
`manifests/`.

There's no `kubectl` on the host. Each cluster ships its own:
`docker exec k3s-<cluster> kubectl …`.

## Argo CD (`argocd/`)

| File                            | What                                                    |
| ------------------------------- | ------------------------------------------------------- |
| `root-app.yaml`                 | App of apps: syncs everything else in `argocd/`         |
| `projects/`                     | AppProjects: what each team may deploy, and where       |
| `appsets/cluster-manifests.yaml`| `manifests/<cluster>/` on every cluster, management too |
| `appsets/kargo-apps-workloads.yaml` | `<app>-<stage>` for every `kargo/apps/<app>.yaml` × `role=workload` cluster |
| `kargo/install.yaml`            | cert-manager, Argo Rollouts, Kargo on management        |
| `kargo/shared.yaml`             | Syncs `kargo/shared/`: steps and test templates for every app |
| `kargo/apps.yaml`               | One `kargo/chart` instance per `kargo/apps/<app>.yaml`  |

The ApplicationSets use Argo CD's **clusters generator**: they select
registered clusters by label instead of listing server URLs. The cluster
Secret's name (`internal`, `stg`, `prod`) picks the overlay and the
`manifests/` directory. Adding a stage means registering a cluster plus
adding its `manifests/<cluster>/` and `apps/pulse-api/overlays/<cluster>/`.
The AppProjects still list allowed destinations explicitly, so a newly
registered cluster can't receive a workload until its project allows it.

## Namespaces

| Namespace   | Clusters            | Notes                         |
| ----------- | ------------------- | ----------------------------- |
| `pulse-api` | internal, stg, prod | Promoted by Kargo |
| `argocd`    | management          | Argo CD |
| `kargo`, `cert-manager`, `argo-rollouts` | management | Kargo and its dependencies |
| `pulse-api` | management          | The Kargo Project: Warehouse, Stages, e2e Jobs |

Each workload namespace gets its own ResourceQuota, LimitRange and
NetworkPolicy (`manifests/<cluster>/00-pulse-api.yaml`), sized per stage.

## Promotion (pulse-api)

A Rust API (`apps/pulse-api`, 1/2/3 replicas on internal/stg/prod). Every
overlay pins an exact image digest. pulse-api's pipeline only builds: it
pushes the app image and its Playwright e2e image with the same `sha-*` tag.
Kargo then promotes that build stage by stage: it commits the new digest to
the stage's overlay, syncs `pulse-api-<stage>` to exactly that commit, and
runs the e2e image against that deployment before the next stage may take
it. The pulse-api Applications have auto-sync off, so only a promotion
deploys them. See [kargo.md](kargo.md).
