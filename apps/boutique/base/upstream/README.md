# Online Boutique (vendored)

`kubernetes-manifests.yaml` is the release manifest of [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) **v0.10.7**, copied unchanged from
`https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/v0.10.7/release/kubernetes-manifests.yaml`.

Online Boutique is © Google LLC, licensed under the Apache License 2.0 (see [LICENSE](LICENSE)). Changes for this platform are made only in `../kustomization.yaml` and the overlays, never in this file, so updating is a plain file replacement.

To update:
1. Download the new release's `release/kubernetes-manifests.yaml` and `LICENSE` over these files.
2. Change the version above and in `../kustomization.yaml`.
3. Open a PR. CI validates the manifests and deploys the whole platform from the PR's commit.
