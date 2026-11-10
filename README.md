# gitops-poc

A local GitOps playground that proves two things:

1. **Argo CD management (hub and spoke):** one Argo CD on a dedicated
   management cluster manages three workload clusters (internal, stg,
   prod). Clusters are selected by label, so registering a cluster is
   enough to deploy to it.
2. **Promotion:** one image digest of
   [pulse-api](https://github.com/glexposito/pulse-api) is promoted
   internal → stg → prod by [Kargo](https://kargo.io). Each stage is
   deployed, then verified by running that build's Playwright tests against
   it, before the next stage may take it. Every deploy is a git commit here.
   pulse-api's GitHub Actions pipeline only builds the images.

Four k3s clusters in Docker. KISS.

## TL;DR

```bash
cd cluster
docker compose up -d      # first start takes a few minutes
```

Argo CD: **https://localhost:9000**, Kargo: **https://localhost:9001** (both
`admin` / `123`, accept the self-signed certificate). You need Docker, and
`gh` for the one-off setup.

**First time only**, before Kargo can promote anything
([details](docs/kargo.md#setup-once)):

1. Give Kargo a git key:
   ```bash
   cd cluster
   ssh-keygen -q -t ed25519 -N "" -f secrets/kargo-git-key -C kargo
   gh repo deploy-key add secrets/kargo-git-key.pub -R glexposito/gitops-poc --allow-write -t kargo
   rm secrets/kargo-git-key.pub
   docker compose up -d --force-recreate argocd-bootstrap
   ```
2. Make the `pulse-api-e2e` package public on GitHub (Packages → pulse-api-e2e →
   Package settings → Change visibility).

Then push to pulse-api `main`: Kargo deploys the build to internal and stg,
running its Playwright tests against each, and waits for you to Promote it to
prod.

| Cluster    | API              | pulse-api        | Runs                  |
| ---------- | ---------------- | ---------------- | --------------------- |
| management | `localhost:6447` |                  | Argo CD, Kargo        |
| internal   | `localhost:6444` | `localhost:8081` | pulse-api (1 replica) |
| stg        | `localhost:6446` | `localhost:8082` | pulse-api (2)         |
| prod       | `localhost:6445` | `localhost:8083` | pulse-api (3)         |

```bash
curl localhost:8083/hostname    # pulse-api on prod: which pod answered
```

## Layout

| Path                   | What                                          | Read by Argo CD |
| ---------------------- | --------------------------------------------- | --------------- |
| `cluster/`             | Compose stack, Argo CD install, bootstrap. Stands in for real cluster infra (Terraform). | No |
| `argocd/`              | Root app, AppProjects, ApplicationSets        | Yes             |
| `apps/pulse-api/`      | Kustomize base + one overlay per stage        | Yes             |
| `kargo/`               | Kargo: shared steps + test templates, per-app chart, one file per app | Yes |
| `manifests/<cluster>/` | Per-cluster namespaces, quotas, policies, RBAC | Yes            |

## Tear down

```bash
cd cluster
docker compose down       # keep state
docker compose down -v    # wipe everything
```

## Docs

- [architecture.md](docs/architecture.md): clusters, Argo CD, promotion
- [kargo.md](docs/kargo.md): promotion with Kargo, setup, adding an app
- [kustomize-conventions.md](docs/kustomize-conventions.md): the Kustomize standard
