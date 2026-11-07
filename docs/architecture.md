# Architecture

## Clusters and bootstrap

Four single-node k3s clusters in Docker: **management** runs only Argo CD, and
**internal / stg / prod** run the workloads. Keeping Argo CD on its own
cluster means losing a workload cluster never takes down the thing that
manages it.

`docker compose up -d` does everything, with no scripts:

1. Each k3s container auto-applies its `manifests/<cluster>/`, which is
   bind-mounted in.
2. k3s installs Argo CD on management from `argocd/helmchart.yaml`.
3. `argocd-bootstrap` registers internal/stg/prod with Argo CD and applies
   `argocd/root-app.yaml`. From then on, Argo CD manages everything from git.

There's no `kubectl` on the host. Each cluster ships its own:
`docker exec k3s-<cluster> kubectl …`.

## Namespaces

| Namespace      | Clusters           | Notes                                       |
| -------------- | ------------------ | ------------------------------------------- |
| `core-workers` | internal, stg, prod | KEDA-scaled queue workers                  |
| `pulse-api`    | internal, stg, prod | Promoted by pulse-api's pipeline           |
| `argocd`       | management         | The only thing management runs              |

Names have no stage suffix, because each cluster is one environment. Each
workload namespace gets its own ResourceQuota, LimitRange and NetworkPolicy
(`manifests/<cluster>/`), sized per environment.

## Argo CD (`argocd/`)

| File                       | What                                                     |
| -------------------------- | -------------------------------------------------------- |
| `helmchart.yaml`           | Argo CD itself, installed by k3s                         |
| `root-app.yaml`            | App of apps: syncs everything else in `argocd/`          |
| `clusters-appset.yaml`     | `manifests/<cluster>/` per cluster                       |
| `keda-appset.yaml`         | KEDA operator per workload cluster                       |
| `core-workers-appset.yaml` | Every stage × worker1/worker2 (6 Applications)           |
| `pulse-api-appset.yaml`    | One per stage; the pipeline commits each stage's digest  |
| `projects/`                | AppProjects: workloads can only touch their own namespace |

## core-workers

Two identical workers (`apps/core-workers`, deployed twice with a name
suffix). KEDA scales them on `core-workers-queue` depth, and they go to zero
when the queue is empty:

| Stage    | 1 replica per | Max |
| -------- | ------------- | --- |
| internal | 50 messages   | 5   |
| stg      | 25 messages   | 10  |
| prod     | 10 messages   | 20  |

```bash
./scripts/queue-messages.sh add 100   # also: remove <n>, count, --help
```

## pulse-api

A Rust API (`apps/pulse-api`, 1/2/3 replicas). Its pipeline builds the image,
then for each stage it pins the digest, runs `argocd app sync`, and runs e2e
before moving on. See [ci-setup.md](ci-setup.md).
