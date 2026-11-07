# Kustomize conventions

The standard every app under `apps/` follows. It's based on the
[Kustomize reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/)
("for more complex use cases, revert to using a patch") and the
[Kubernetes Kustomize guide](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
("small patches that do one thing are recommended").

## 1. Layout

```
apps/<app>/
  base/                 # everything every stage shares - valid on its own
  overlays/<stage>/     # only what differs on that stage
    kustomization.yaml
    <concern>.yaml      # patches, if any (rule 4)
```

Overlays never copy base resources. If a stage needs something different,
change it with a field (rule 2) or a patch (rule 4).

## 2. Use a built-in field when one exists

| Change                        | Use                                         |
| ----------------------------- | ------------------------------------------- |
| Image, tag, digest            | `images:` (see rule 3)                      |
| Replica count                 | `replicas:`                                 |
| Namespace                     | `namespace:`                                |
| Labels / annotations          | `labels:` / `commonAnnotations:`            |
| Name prefix / suffix          | `namePrefix:` / `nameSuffix:`               |
| ConfigMap / Secret contents   | `configMapGenerator:` / `secretGenerator:`  |

Don't use a patch for any of these.

## 3. Images that CI promotes go through `images:`

- base: the image **without a tag** (`ghcr.io/glexposito/pulse-api`).
- each overlay: an `images:` entry for it. CI pins the exact digest with
  `kustomize edit set image <name>@sha256:...`, which is also what Argo CD
  Image Updater and Kargo write. Never put a promoted image in a patch:
  no tool would update it.
- Only hand-edit a digest to roll back.

An image that never changes per stage (e.g. core-workers'
`nginxdemos/hello`) can stay pinned in base.

## 4. Patches: only when no field fits, one concern per file

- One reason to change per patch, named after it: `app_env.yaml`,
  `scaling.yaml`, `resources.yaml`, `probes.yaml`. A change made of several
  fields that only make sense together (a sidecar plus its volume) is still
  one concern, so it's one file.
- Prefer **strategic merge** patches (a partial resource, matched by
  kind + name), e.g. `apps/core-workers/overlays/*/app_env.yaml`.
- Use **JSON 6902** (`op: replace`) only where a strategic merge can't
  reach, like a list item without a merge key (CRDs such as KEDA's
  ScaledObject), and guard index-based paths with an `op: test`. See
  `apps/core-workers/overlays/*/scaling.yaml`.

## 5. Check the render

```bash
kubectl kustomize apps/<app>/overlays/<stage>
```
