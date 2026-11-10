# Architecture

## Clusters and bootstrap

Four single-node k3s clusters in Docker (`cluster/docker-compose.yaml`):
**management** runs only Argo CD, and **internal / stg / prod** are the
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
| `appsets/pulse-api.yaml`        | pulse-api on every `role=workload` cluster              |

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
| `pulse-api` | internal, stg, prod | Promoted by pulse-api's pipeline |
| `argocd`    | management          | The only thing management runs |

Each workload namespace gets its own ResourceQuota, LimitRange and
NetworkPolicy (`manifests/<cluster>/00-pulse-api.yaml`), sized per stage.

## Promotion (pulse-api)

A Rust API (`apps/pulse-api`, 1/2/3 replicas on internal/stg/prod). Every
overlay pins an exact image digest. pulse-api's pipeline builds the image
once, then for each stage it commits the new digest to that stage's
overlay, runs `argocd app sync` to that exact commit, and runs e2e before
moving on. The pulse-api Applications have auto-sync off for that reason.
See [ci-setup.md](ci-setup.md).
