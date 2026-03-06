# linkerd-trust-anchor-refresh

[![CI](https://github.com/hoshsadiq/linkerd-trust-anchor-refresh/actions/workflows/ci.yaml/badge.svg)](https://github.com/hoshsadiq/linkerd-trust-anchor-refresh/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Automatically restarts Linkerd-injected workloads after trust anchor certificate rotation. This can probably be done by some other tool, but the ones I found were overkill for this use-case.

## The Problem

When Linkerd's trust anchor certificate is rotated (e.g. by cert-manager), existing pods keep the old trust anchor. This is because the Linkerd proxy injector injects the trust anchor as an environment variable at pod creation time and the proxy reads it once at startup and never reloads it.

After rotation, pods with stale trust anchors cannot validate certificates signed by the new issuer, resulting in `DEADLINE_EXCEEDED` and `BadSignature` errors across your mesh.

See [linkerd/linkerd2#13613](https://github.com/linkerd/linkerd2/issues/13613) for the upstream issue.

This essentially builds on [Hands off Linkerd certificate rotation](https://linkerd.io/2025/10/20/hands-off-linkerd-certificate-rotation/index.html) by [Matthew McLane](https://medium.com/@mclanem_45809).

## How It Works

A Kubernetes CronJob runs on a configurable schedule (default: daily at 2am) and:

1. Checks the `linkerd-identity-issuer` secret for the certificate's `notBefore` timestamp
2. Restarts all deployments in the `linkerd` namespace
3. Finds Linkerd-injected Deployments, StatefulSets, and DaemonSets whose pods started before the certificate was issued
4. Finally, it restarts stale workloads

The CronJob is annotated with `linkerd.io/inject: disabled` so it doesn't depend on the very trust anchor it's refreshing.

## Installation

### Using the Helm repository

```bash
helm repo add linkerd-trust-anchor-refresh https://hoshsadiq.github.io/linkerd-trust-anchor-refresh
helm repo update

helm install linkerd-trust-anchor-refresh linkerd-trust-anchor-refresh/linkerd-trust-anchor-refresh \
  --namespace linkerd \
  --create-namespace
```

### Using OCI

```bash
helm install linkerd-trust-anchor-refresh \
  oci://ghcr.io/hoshsadiq/charts/linkerd-trust-anchor-refresh \
  --namespace linkerd \
  --create-namespace
```

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `schedule` | Cron expression for the refresh check | `"0 2 * * *"` |
| `image.repository` | Container image repository | `ghcr.io/hoshsadiq/linkerd-trust-anchor-refresh` |
| `image.tag` | Container image tag | `0.1.0` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `staggerDelaySeconds` | Delay between restarting workloads in different namespaces | `30` |
| `rolloutTimeoutMinutes` | Timeout for each rollout restart to complete | `10` |

## Requirements

- Kubernetes 1.26+
- Linkerd with trust anchor managed by cert-manager (or any automated rotation)
- The CronJob's service account needs cluster-wide read access to namespaces, secrets, pods, and patch access to deployments, statefulsets, and daemonsets

## License

[MIT](LICENSE)

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
