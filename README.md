# gitops-poc

A local GitOps playground that proves two things:

1. **Argo CD management (hub and spoke):** one Argo CD on a dedicated
   management cluster manages three workload clusters (internal, stg,
   prod). Clusters are selected by label, so registering a cluster is
   enough to deploy to it.
2. **Promotion:** one image digest of
   [pulse-api](https://github.com/glexposito/pulse-api) is promoted
   internal → stg → prod. Each stage runs e2e checks before the next one
   starts, and every deploy is a git commit here.
   Two ways side by side: **CI-driven** (GitHub Actions pushes and syncs)
   and **controller-driven** ([Kargo](https://kargo.io) on management).

Four k3s clusters in Docker. KISS.

## TL;DR

```bash
cd cluster
docker compose up -d      # first start takes a few minutes
```

Argo CD: **https://localhost:9000**, Kargo: **https://localhost:9001** (both
`admin` / `123`). You only need Docker.

| Cluster    | API              | pulse-api (CI)   | pulse-api (Kargo) | Runs                  |
| ---------- | ---------------- | ---------------- | ----------------- | --------------------- |
| management | `localhost:6447` |                  |                   | Argo CD, Kargo        |
| internal   | `localhost:6444` | `localhost:8081` | `localhost:8091`  | pulse-api (1 replica) |
| stg        | `localhost:6446` | `localhost:8082` | `localhost:8092`  | pulse-api (2)         |
| prod       | `localhost:6445` | `localhost:8083` | `localhost:8093`  | pulse-api (3)         |

```bash
curl localhost:8083/hostname    # pulse-api on prod: which pod answered
```

## Layout

| Path                   | What                                          | Read by Argo CD |
| ---------------------- | --------------------------------------------- | --------------- |
| `cluster/`             | Compose stack, Argo CD install, bootstrap, CI runner. Stands in for real cluster infra (Terraform). | No |
| `argocd/`              | Root app, AppProjects, ApplicationSets        | Yes             |
| `apps/pulse-api/`      | Kustomize base + one overlay per stage (CI path) | Yes          |
| `apps/pulse-api-kargo/` | Same app, own overlays + NodePort (Kargo path) | Yes           |
| `kargo/pulse-api/`     | Kargo Project, Warehouse, Stages, e2e template | Yes            |
| `manifests/<cluster>/` | Per-cluster namespaces, quotas, policies, RBAC | Yes            |

## Tear down

```bash
cd cluster
docker compose down       # keep state
docker compose down -v    # wipe everything
```

## Docs

- [architecture.md](docs/architecture.md): clusters, Argo CD, promotion
- [ci-setup.md](docs/ci-setup.md): pulse-api pipeline, runner, credentials
- [kargo.md](docs/kargo.md): the Kargo path, setup, how to compare
- [kustomize-conventions.md](docs/kustomize-conventions.md): the Kustomize standard
