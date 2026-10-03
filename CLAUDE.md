# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`ex-cicd-tektonpac` is a worked example of **Tekton Pipelines as Code (PAC)**
CI/CD for a Java app. It is both:

1. A minimal Spring Boot (Java 17 / Maven) app (`src/`, `pom.xml`, `Dockerfile`) — just enough to give the pipelines something real to build and test.
2. The `.tekton/` pipeline definitions and `infra/pac/` cluster setup that make PAC build/test PRs and, on merge to `main`, build+push an image and bump the tag in a companion GitOps repo.

The interesting content of this repo is the CI/CD wiring, not the app itself.

## Commands

```bash
mvn test                 # run tests only
mvn package              # test + build the jar (what the PR and push pipelines run)
mvn test -Dtest=DemoApplicationTests   # run a single test class
mvn package && docker build -t demo-app .   # build the image locally; the Dockerfile is runtime-only and COPYs target/*.jar, so the jar must exist first
```

Pipeline validation without a live GitHub event:
```bash
tkn pac resolve -f .tekton/pr.yaml -o /tmp/pr-resolved.yaml   # render the PipelineRun
kubectl create -f /tmp/pr-resolved.yaml                        # actually run it against a dev cluster
kubectl apply --dry-run=client -f .tekton/pr.yaml               # basic YAML/schema sanity check
```

Standalone CI pipeline in `tekton_ci/` (not read by PAC — applied and run by hand):
```bash
kubectl apply --dry-run=server -n cicd-demo -f tekton_ci/task.yaml -f tekton_ci/pipeline.yaml   # schema check
kubectl apply  -n cicd-demo -f tekton_ci/task.yaml -f tekton_ci/pipeline.yaml
kubectl create -n cicd-demo -f tekton_ci/pipelinerun.yaml   # edit repo_url / revision in the file first
```

There is no lint/format tooling configured beyond `mvn test`.

## Architecture

Two GitHub repos, one GitHub App, one PAC install, one `cicd-demo` namespace:

```
[Developer] --push/PR--> [GitHub: this repo (app-repo)]
                              |  webhook (GitHub App)
                              v
                 [PAC controller/webhook/watcher on cluster]
                              |  resolves .tekton/*.yaml + Tasks
                              v
                      [PipelineRun in cicd-demo namespace]
        pr.yaml:   git-clone -> maven package -> buildah build (no push)
        push.yaml: git-clone -> maven package -> buildah build+push -> update-deployment-tag
                                                                             |
                                                                             v
                                                          [GitHub: ex-cicd-tektonpac-deploy
                                                           charts/demo-app/values.yaml image.tag bumped]
```

Key pieces and where they live:
- `.tekton/pr.yaml` — runs on `pull_request` → `main`: clone, `mvn package`, throwaway image build tagged `pr-{{ pull_request_number }}` (`SKIP_PUSH: true`). No write access needed.
- `.tekton/push.yaml` — runs on `push` → `main`: clone, `mvn package`, build+push image to `ghcr.io/catsrang/demo-app:{{ revision }}`, then runs the custom `update-deployment-tag` Task.
- `.tekton/tasks/update-deployment-tag.yaml` — custom Task: clones the deploy repo using PAC's short-lived `{{ git_auth_secret }}` (GitHub App installation token), patches `charts/demo-app/values.yaml`'s `image.tag` with `yq`, commits, pushes to `main`.
- `Dockerfile` — runtime-only: it `COPY`s `target/demo-0.0.1-SNAPSHOT.jar` from the build context and compiles nothing. Every pipeline must therefore run `mvn package` *before* `buildah`; a Maven goal that stops at `test` fails one task later, at the image build, on the missing jar.
- `tekton_ci/` — standalone (non-PAC) CI: `task.yaml` (`clone-build-memory`: clone + `mvn package` on a memory-backed workspace, then copy only the jar + `Dockerfile` to a PVC), `pipeline.yaml` (that Task → `buildah` via the hub resolver, no push), `pipelinerun.yaml` (binds a 2Gi `emptyDir{medium: Memory}` and a 1Gi PVC). Clone and build are one Task on purpose: an `emptyDir` is per-pod, so it cannot be shared between Tekton tasks — only the PVC is.
- `infra/pac/` — cluster-side, one-time setup: `install.sh`/`verify.sh` (PAC controller on vanilla K8s), `ingress.yaml` (webhook delivery via Traefik at `/pac` on the existing dashboard host), `repository.yaml` / `repository-deploy.yaml` (`Repository` CRs registering both repos with PAC), `github-app/` (App creation runbook + `create-secret.sh`).
- Companion repo `catsrang/ex-cicd-tektonpac-deploy` is the GitOps target (`charts/demo-app/values.yaml`); it has **no `.tekton/` files** — its `Repository` CR exists purely to satisfy PAC's cross-repo token-scoping check (see Gotcha #2 below), not to trigger its own runs.

PAC resolves Task references (`git-clone`, `maven`, `buildah` from Tekton Hub; `update-deployment-tag` from the same repo by relative path) into one self-contained `PipelineRun` at event time — nothing is pre-bundled.

## Non-obvious things worth knowing before touching `.tekton/` or `infra/pac/`

These were hard-won in the initial implementation (`topic/20260820-1_init_tekton_cicd_example/30.impl.md`, full log; `tektonpac_impl_guide.md`, distilled step-by-step guide with numbered Gotchas #0–#9). Skim the Gotchas before debugging a pipeline failure — most failure modes below have already been hit once:

- **App must be installed on *both* repos in the same sitting.** GitHub's "Configure → Select repositories" flow can silently *replace* rather than extend the App's repo-access list, so adding the deploy repo later can drop this repo out. Verify via `https://github.com/settings/installations` → Configure, not just the repo's own installations page.
- **`github_app_token_scope_repos` requires the scoped repo to have its own `Repository` CR** in the same namespace (even with no `.tekton/` files) — otherwise the push pipeline fails at token-scoping with `failed to scope GitHub token as repo ... does not exist in namespace cicd-demo`. This is what `repository-deploy.yaml` is for.
- **`{{ git_auth_secret }}` does not substitute inside an inlined custom Task's `env` block** — it must come in via a `workspace` (see how `update-deployment-tag.yaml` reads the token from `$(workspaces.basic-auth.path)/git-provider-token` instead).
- **`yq` is not a `microdnf` package on UBI minimal images** — it's downloaded as a pinned binary release (see the `curl` line in `update-deployment-tag.yaml`); don't swap this for a package-manager install without checking.
- **The `ghcr-credentials` Secret's key must be literally `config.json`**, not `.dockerconfigjson` (that's the `kubectl create secret docker-registry` default — this Task expects the raw Docker config key instead).
- **`pipelinerun_provenance: default_branch`** (set on this repo's `Repository` CR) resolves `.tekton/` from `main`, not the PR head — a deliberate security default so a fork PR can't ship its own pipeline definition. Don't "fix" pipeline changes by editing a PR branch's `.tekton/` files and expecting them to take effect before merge.
- Full architecture diagram, prerequisites, and a numbered step-by-step reproduction guide (with real verified command output per step) live in `tektonpac_impl_guide.md` — read it before re-running any of the cluster/App bootstrap steps in `infra/pac/`.
