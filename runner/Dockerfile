# The github-runner Compose service's image: GitHub's official runner image
# (built from github.com/actions/runner) plus the two CLIs pulse-api's
# deploy jobs need, baked in so no job downloads them. argocd matches the
# server version pinned in argocd/helmchart.yaml.
#
# The official image only ships the runner - it doesn't register itself -
# so entrypoint.sh does that from GITHUB_PAT/RUNNER_REPO.
FROM ghcr.io/actions/actions-runner:2.338.2

ARG ARGOCD_VERSION=v3.5.2
ARG KUSTOMIZE_VERSION=v5.8.3

USER root
RUN curl -fsSL -o /usr/local/bin/argocd \
      "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" \
    && chmod +x /usr/local/bin/argocd \
    && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin kustomize
COPY --chmod=755 entrypoint.sh /entrypoint.sh

USER runner
ENTRYPOINT ["/entrypoint.sh"]
