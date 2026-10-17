# Online Boutique frontend (vendored source)

This directory is `src/frontend` of [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) **v0.10.7** (tag `v0.10.7`, commit `5b608cb`), the same release as the manifests in `apps/boutique/base/upstream/`.

Online Boutique is © Google LLC, licensed under the Apache License 2.0 (see [LICENSE](LICENSE), copied from the repository root).

## Changes from upstream

The first commit that added this directory is the upstream code unchanged, so `git diff` against it shows every change made here:

| File | Change | Why |
|---|---|---|
| `failrate.go`, `failrate_test.go` | New. The `FAIL_RATE` switch: a share of requests (0 to 1) gets HTTP 500. `/_healthz` is never failed. Unset or `0` means off | Phase 4 uses it as the bad release in the canary drill (DECISIONS #20) |
| `main.go` | Wraps the router with the `FAIL_RATE` handler and logs the rate at start-up; an invalid value stops the frontend | |
| `Dockerfile` | The runtime image `gcr.io/distroless/static` pinned by digest; a `test` stage that runs `go test ./...` | Every build uses the same base image; CI runs the tests with the same Go image that builds the binary (DECISIONS #18) |
| `VENDORED.md` | This file | |

## Updating to a new release

1. Replace this directory with the new release's `src/frontend` and commit that unchanged.
2. Re-apply the changes in the table above in a second commit.
3. Change the version here, in `apps/boutique/base/upstream/README.md` and in the manifests, and open a PR.
