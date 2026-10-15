# Evidence

Real runs that show Phase 1 working. CI repeats the full check on every pull request and every push to `main`: [all runs](https://github.com/kaushik-sai/gitops-platform/actions/workflows/ci.yml).

## 1. First CI run on `main` (GitHub-hosted runner)

| | |
|---|---|
| Run | [38688133728](https://github.com/kaushik-sai/gitops-platform/actions/runs/38688133728), push to `main`, 2026-10-15 |
| Commit | `dc0b135` (Phase 1) |
| Result | **success**, 3 min 57 s from start to finish |

### `validate`: 35 s

| Step | Result | Time |
|---|---|---|
| PSScriptAnalyzer | no errors or warnings | 7 s |
| Pester | 79 passed, 0 failed | 7 s |
| kubeconform, `apps/boutique/overlays/dev` | 32 resources, 32 valid | 3 s (both overlays) |
| kubeconform, `apps/boutique/overlays/prod` | 34 resources, 34 valid | |
| kubeconform, `clusters/local` (Argo CD Application schema) | 2 resources, 2 valid | 1 s |

### `e2e`: 195 s

The runner starts with nothing. `Start-Platform.ps1` created a new kind cluster (kind v0.33.0), installed Argo CD (chart 10.10.3) and pointed it at this repository at `dc0b135734ce6dc27511cc4ee864b87dacd814f6`. Argo CD then cloned that commit from GitHub and deployed both environments.

| Step | Result | Time |
|---|---|---|
| Tools: kind and Helm (SHA-256 checked) | ok | 17 s |
| `Start-Platform.ps1`: cluster, Argo CD, root, wait | `root`, `boutique-dev`, `boutique-prod` all Synced and Healthy | 165 s |
| `Test-Smoke.ps1 -Environment dev` | 4/4 PASS | 4 s |
| `Test-Smoke.ps1 -Environment prod` | 4/4 PASS | 4 s |
| Diagnostics | skipped (only runs on failure) | |

The wait loop prints the table whenever it changes. These are the four tables it printed (headers left out):

```
root          Unknown Unknown

boutique-dev  Synced  Progressing
boutique-prod Synced  Progressing
root          Synced  Healthy

boutique-dev  Synced  Healthy
boutique-prod Synced  Progressing
root          Synced  Healthy

boutique-dev  Synced  Healthy
boutique-prod Synced  Healthy
root          Synced  Healthy
Platform is up: every Application is Synced and Healthy.
```

Smoke checks, the same in both environments:

```
PASS boutique-dev /_healthz: HTTP 200, found 'ok'
PASS boutique-dev /: HTTP 200, found 'Online Boutique'
PASS boutique-dev /product/OLJCESPC7Z: HTTP 200, found 'Sunglasses'
PASS boutique-dev /cart: HTTP 200, found 'Shopping Cart'
```

All the pods fit on the runner's 4 vCPUs: the platform requests 3790m of CPU (see the resource budget in [DESIGN.md](../DESIGN.md)).

## 2. The laptop (Windows 11, Docker Desktop 7.6 GiB, 12 CPUs)

| Run | Result |
|---|---|
| `Start-Platform.ps1 -NoWait` from nothing | kind cluster and Argo CD in 128 s |
| Both overlays applied with `kubectl apply -k` (before the repository existed) | 23 pods Running in 191 s, including image pulls |
| `Test-Smoke.ps1` dev and prod | 8/8 PASS; no port-forward process left behind |
| `Start-Platform.ps1` again, after the first push | Reused the cluster, upgraded Argo CD in place, and waited until all three Applications were Synced and Healthy at `dc0b135`, synced from GitHub. 16 s, so running it again is safe and quick |
| Node usage with both environments and Argo CD | 2.27 GiB of memory |
