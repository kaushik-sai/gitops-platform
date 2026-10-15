# RUNBOOK: local platform (Phase 1)

Troubleshooting the kind cluster, Argo CD and Online Boutique on the laptop. Run the commands from the repo root in PowerShell 7. They use the default cluster `gitops-local`, so the context is `kind-gitops-local` and the node container is `gitops-local-control-plane`. With `-ClusterName <name>`, use `kind-<name>` and `<name>-control-plane`.

Every command names the context, so it never acts on another cluster.

## Where to look

| What | Command or place |
|---|---|
| Applications: sync and health | `kubectl --context kind-gitops-local -n argocd get applications.argoproj.io` |
| One Application in detail (conditions, last sync) | `kubectl --context kind-gitops-local -n argocd describe application boutique-dev` |
| Argo CD UI (health per resource, sync errors) | `kubectl --context kind-gitops-local -n argocd port-forward svc/argocd-server 8080:80`, then http://127.0.0.1:8080 |
| Pods in an environment | `kubectl --context kind-gitops-local -n boutique-dev get pods` |
| Warning events, all namespaces | `kubectl --context kind-gitops-local get events -A --field-selector type=Warning` |
| Node capacity and requests | `kubectl --context kind-gitops-local describe node gitops-local-control-plane` (section "Allocated resources") |
| Docker and the node container | `docker info`, `docker ps -a --filter name=gitops-local-control-plane`, `docker stats --no-stream gitops-local-control-plane` |

## The cluster won't start

**Symptoms.** `Start-Platform.ps1` stops with one of:
- `Docker is not running. Start Docker Desktop (Linux containers) and run this again.`
- `<tool> is not on PATH. See Prerequisites in README.md.`
- `kind create cluster failed (exit <n>).`
- `helm upgrade --install argocd failed (exit <n>).`

**Check.**

```powershell
docker info --format '{{.OSType}} {{.NCPU}} CPUs {{.MemTotal}} bytes'   # expect "linux"; 7.6 GiB shows as about 8160000000 bytes
kind get clusters
docker ps -a --filter name=gitops-local-control-plane
```

| Cause | Fix |
|---|---|
| Docker Desktop not running | Start it, wait until the engine is running, run `Start-Platform.ps1` again |
| Docker Desktop in Windows containers mode (`OSType` is `windows`) | Switch to Linux containers, run again |
| Too little memory for Docker | WSL 2 backend: set `memory=` under `[wsl2]` in `%UserProfile%\.wslconfig`, run `wsl --shutdown`, restart Docker Desktop. Hyper-V backend: Settings > Resources > Advanced. About 7.6 GiB is what this was built with |
| The node container exists but is stopped (for example after Docker Desktop restarted) | `docker start gitops-local-control-plane`, then run `Start-Platform.ps1` again. If it still fails, reset (below) |
| A cluster was half created | Reset (below) |
| `helm upgrade --install argocd` failed or timed out (10 min) | `kubectl --context kind-gitops-local -n argocd get pods`. Usually image pulls or memory: see those sections. Then run `Start-Platform.ps1` again; it upgrades in place |

To keep a failed node for inspection, create the cluster by hand with `--retain`, export its logs, then delete it:

```powershell
kind create cluster --name gitops-local --config bootstrap/kind-config.yaml --retain
kind export logs ./out/kind-logs --name gitops-local     # out/ is git-ignored
pwsh ./scripts/Stop-Platform.ps1
```

## An Application is OutOfSync, Progressing, or shows ComparisonError

**Symptoms.** `Start-Platform.ps1` ends with `Timed out after 900 s waiting for every Application to be Synced and Healthy:` and the last status table. Or the Argo CD UI shows an Application that is not Synced and Healthy.

**Check.**

```powershell
kubectl --context kind-gitops-local -n argocd get applications.argoproj.io
kubectl --context kind-gitops-local -n argocd describe application boutique-dev        # read Status > Conditions and Operation State

# Which repository and revision is the platform deploying?
kubectl --context kind-gitops-local -n argocd get application root -o jsonpath='{.spec.source.repoURL} {.spec.source.targetRevision}'

# Does that revision exist on GitHub? (no output: it does not)
git ls-remote https://github.com/kaushik-sai/gitops-platform.git feature/my-change

# Git fetch and render errors are in the repo server; sync and health in the application controller
kubectl --context kind-gitops-local -n argocd logs deploy/argocd-repo-server --tail 100
kubectl --context kind-gitops-local -n argocd logs pod/argocd-application-controller-0 --tail 100
```

| What you see | Usual cause | Fix |
|---|---|---|
| ComparisonError; the message says the repository cannot be reached, is not found, or needs authentication | No internet; the repository is not pushed yet; it is private (Argo CD has no repository credentials here); wrong `-RepoUrl` | Fix the network, push the repository or make it public, or run `Start-Platform.ps1 -RepoUrl <url>` with the right URL |
| ComparisonError; the message says the revision cannot be resolved | The branch is not pushed, or `-Revision` has a typo | `git push origin <branch>`, or run `Start-Platform.ps1 -Revision <right value>` |
| ComparisonError; path not found, or a kustomize or Helm error | The overlay or chart is missing or broken at that revision | Reproduce with `kubectl kustomize apps/boutique/overlays/dev` or `helm template clusters/local` at that commit; fix in a PR |
| OutOfSync and the last sync Failed | The API server rejected a manifest; the reason is in Operation State | Fix it in Git. No `syncPolicy.retry` is set here, so Argo CD may not retry an automated sync that failed on the same commit: push the fix as a new commit |
| OutOfSync for a moment after a manual `kubectl` change | Self-heal is reverting the change | Expected. Make the change in Git instead |
| Synced but Progressing for minutes | A Deployment is not Available: pods Pending, image pull errors or crash loops | `kubectl --context kind-gitops-local -n boutique-dev get pods`, then the sections below |
| `loadgenerator` (prod) stuck in `Init` | Its init container waits for the frontend: 12 tries, 10 s apart, then it fails and Kubernetes starts it again | Fix the frontend first; the load generator follows |
| Synced and Healthy, but on an old commit | Argo CD has not looked at Git again yet (about every 60 s) | Wait, or ask for a hard refresh (below) |

```powershell
# Ask Argo CD to read Git again now (root first; it passes the revision to the children)
kubectl --context kind-gitops-local -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl --context kind-gitops-local -n argocd annotate application boutique-dev argocd.argoproj.io/refresh=hard --overwrite
```

**Break-glass: the admin account.** The UI is read-only. If you must press Sync or look at something only an admin can see, sign in as `admin`:

```powershell
$encoded = kubectl --context kind-gitops-local -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
```

Then open http://127.0.0.1:8080/login (port-forward running) and sign in as `admin`. A change made in the UI is not in Git: self-heal reverts it or it is lost at the next reset. The real fix still goes through a PR.

## Pods are Pending (memory)

**Symptoms.** Pods stay `Pending`; `describe pod` shows an event like `0/1 nodes are available: 1 Insufficient memory.` Or containers restart with `OOMKilled` as their last state.

**Check.**

```powershell
kubectl --context kind-gitops-local get pods -A --field-selector status.phase=Pending
kubectl --context kind-gitops-local -n boutique-prod describe pod <pod>              # Events at the bottom
kubectl --context kind-gitops-local describe node gitops-local-control-plane       # Allocatable vs Allocated resources
docker stats --no-stream gitops-local-control-plane                                 # real memory use of the whole node
docker ps                                                                           # anything else using Docker's memory?
kind get clusters                                                                   # other kind clusters?
```

Boutique requests 1112 Mi in dev and 1368 Mi in prod (budget in [DESIGN.md](DESIGN.md#resource-budget)).

**Fix.**
1. Stop other containers and delete other kind clusters you do not need.
2. If that is not enough, give Docker more memory (see "The cluster won't start").
3. Reset (below), so every pod is scheduled again from a clean node.

`Insufficient cpu` works the same way: Boutique requests 2.84 CPU for both environments, before Argo CD and Kubernetes itself.

## Image pull errors

**Symptoms.** Pods show `ErrImagePull` or `ImagePullBackOff`.

| Image | Registry |
|---|---|
| Boutique services: `us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/<service>:v0.10.7` | Google Artifact Registry (public) |
| `redis:alpine`, `busybox:1.38.0@sha256:...` | Docker Hub |
| `kindest/node:v1.37.0@sha256:...` | Docker Hub (pulled by Docker on the host when the cluster is created) |
| Argo CD images | as set by chart `argo-cd` 10.10.3 |
| The Argo CD chart | `oci://ghcr.io/argoproj/argo-helm/argo-cd` (pulled by Helm on the host) |

**Check.**

```powershell
kubectl --context kind-gitops-local -n boutique-dev get pods
kubectl --context kind-gitops-local -n boutique-dev describe pod <pod>         # Events name the image and the registry's error
docker exec gitops-local-control-plane crictl pull <image>                     # pull from inside the node, the same way the kubelet does
```

| Cause | Fix |
|---|---|
| No internet, DNS or proxy problem | Fix the network. The kubelet retries with a back-off; to retry now, delete the pod and its Deployment creates a new one: `kubectl --context kind-gitops-local -n boutique-dev delete pod <pod>` |
| Docker Hub rate limit (`toomanyrequests`) | Anonymous pulls are limited per IP address. Wait, then delete the pod to retry |
| Wrong image name or tag after a change in Git | Fix it in Git. `describe pod` shows the exact image the kubelet tried |

## Smoke test fails

**Symptoms.** `Test-Smoke.ps1` prints `FAIL boutique-<env> <path>: <detail>`, or `The frontend in boutique-<env> did not answer /_healthz within 60 s.`

```powershell
kubectl --context kind-gitops-local -n argocd get applications.argoproj.io              # both Synced and Healthy?
kubectl --context kind-gitops-local -n boutique-dev get pods                            # all Running and ready?
kubectl --context kind-gitops-local -n boutique-dev logs deploy/frontend --tail 100      # the failed backend call is logged here
Get-Content (Join-Path ([IO.Path]::GetTempPath()) 'port-forward-boutique-dev.err')    # the smoke test's port-forward errors
pwsh ./scripts/Test-Smoke.ps1 -Environment dev -LocalPort 18090                         # if port 18080 is already in use
```

## Reset everything

The cluster holds nothing that is not in Git, so a reset loses nothing:

```powershell
pwsh ./scripts/Stop-Platform.ps1
pwsh ./scripts/Start-Platform.ps1          # add -Revision <branch> to come back on a branch
```

- Images pulled inside the node are deleted with it and pulled again. The node image stays in Docker.
- Argo CD generates a new `admin` password.

## Logs and events

```powershell
# Warning events in every namespace, oldest first
kubectl --context kind-gitops-local get events -A --field-selector type=Warning --sort-by .metadata.creationTimestamp

# Everything that happened in one namespace
kubectl --context kind-gitops-local -n boutique-prod get events --sort-by .metadata.creationTimestamp

# A service (one container per Deployment, except loadgenerator)
kubectl --context kind-gitops-local -n boutique-prod logs deploy/frontend --tail 100
kubectl --context kind-gitops-local -n boutique-prod logs deploy/frontend --previous      # the container before the last restart

# The load generator (prod only): init container, then the main container
kubectl --context kind-gitops-local -n boutique-prod logs deploy/loadgenerator -c frontend-check
kubectl --context kind-gitops-local -n boutique-prod logs deploy/loadgenerator -c main --tail 100

# Argo CD
kubectl --context kind-gitops-local -n argocd get pods
kubectl --context kind-gitops-local -n argocd logs deploy/argocd-server --tail 100
kubectl --context kind-gitops-local -n argocd logs deploy/argocd-repo-server --tail 100
kubectl --context kind-gitops-local -n argocd logs pod/argocd-application-controller-0 --tail 100

# The node: kubelet, containerd and control plane logs, into the git-ignored out/
kind export logs ./out/kind-logs --name gitops-local
```
