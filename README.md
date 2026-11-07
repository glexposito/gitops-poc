# k8s-keda-poc

A throwaway local GitOps playground: four k3s clusters in Docker, one Argo CD
managing internal/stg/prod, KEDA autoscaling queue workers, and a pipeline
promoting [pulse-api](https://github.com/glexposito/pulse-api) through the
stages. KISS.

## TL;DR

```bash
docker compose up -d      # first start takes a few minutes
```

Argo CD: **https://localhost:9000** (`admin` / `123`). You only need Docker.

| Cluster    | API              | pulse-api        | Runs                                        |
| ---------- | ---------------- | ---------------- | ------------------------------------------- |
| management | `localhost:6447` |                  | Argo CD                                     |
| internal   | `localhost:6444` | `localhost:8081` | core-workers (max 5), pulse-api (1 replica) |
| stg        | `localhost:6446` | `localhost:8082` | core-workers (max 10), pulse-api (2)        |
| prod       | `localhost:6445` | `localhost:8083` | core-workers (max 20), pulse-api (3)        |

## Try it

```bash
./scripts/queue-messages.sh add 100                      # KEDA scales the workers up
docker exec k3s-prod kubectl -n core-workers get pods -w
./scripts/queue-messages.sh remove 100                   # ...and back to zero

curl localhost:8083/hostname                             # pulse-api on prod: which pod answered
```

## Tear down

```bash
docker compose down       # keep state
docker compose down -v    # wipe everything
```

## Docs

- [architecture.md](docs/architecture.md): clusters, Argo CD, the two apps
- [ci-setup.md](docs/ci-setup.md): pulse-api pipeline, runner, credentials
- [kustomize-conventions.md](docs/kustomize-conventions.md): the Kustomize standard
