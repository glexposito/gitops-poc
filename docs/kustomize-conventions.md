# Kustomize conventions

The standard every app under `apps/` follows. It's based on the
[Kustomize reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/)
and the [Kubernetes guide](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/).

1. **Layout:** `apps/<app>/base/` holds everything shared.
   `overlays/<stage>/` holds only what differs on that stage. Never copy
   base files into an overlay.
2. **Use a built-in field when one exists:** `images:`, `replicas:`,
   `namespace:`, `labels:`, `namePrefix`/`nameSuffix`,
   `configMapGenerator`/`secretGenerator`.
3. **Promoted images:** the base has the image with no tag. Each overlay
   has an `images:` entry, and Kargo pins its digest with its
   `kustomize-set-image` step. Never put a promoted image in a patch, because
   no tool would update it.
4. **Use patches only when no field fits**, one concern per file, named
   after it (`app_env.yaml`, `resources.yaml`). Prefer strategic merge.
   Use JSON 6902 only for what strategic merge can't reach, like CRD list
   items, and guard index paths with `op: test`.

Check the result with `kubectl kustomize apps/<app>/overlays/<stage>`.
