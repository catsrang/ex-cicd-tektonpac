# Pipelines as Code (PAC) — Step-by-Step Java CI/CD Guide

*Refined against the current pipelinesascode.com documentation (Aug 2026).*

This guide walks through setting up [Pipelines as Code](https://pipelinesascode.com/) (PAC) for a Java (Spring Boot + Maven) application on GitHub, using the same `app-repo` / `deployment-repo` split as the project's existing Tekton Triggers-based guides. PAC replaces the manual **GitHub PAT + EventListener/TriggerBinding/TriggerTemplate** setup with a **GitHub App + `.tekton/` pipeline files committed in the repo**.

> Task/CLI flag names can change between PAC versions — always cross-check against the version installed on your cluster (`tkn pac version`). `hub.tekton.dev` itself wasn't reachable from this session, so the exact Maven/Buildah Task parameter names below (`GOALS`, `IMAGE`, etc.) are the commonly-used ones but should be diffed against whatever version resolves on your cluster before relying on them verbatim.

---

## 0. Architecture

```
[Developer]
    │ git push / open PR
    ▼
[GitHub: app-repo (Java)]  ── .tekton/pr.yaml, .tekton/push.yaml live here
    │ GitHub App webhook (Checks API)
    ▼
[Pipelines as Code controller/webhook/watcher on cluster]
    ├─ matches event → PipelineRun in .tekton/
    ├─ resolves Tasks (Tekton Hub / local file / URL) and inlines them
    ├─ runs the resolved PipelineRun as a normal Tekton PipelineRun
    └─ reports status back to GitHub Checks tab (+ PR comment on parse errors)
         │
         ▼ (on push to main only)
[GitHub: deployment-repo (Helm values.yaml)] ← image tag updated & pushed
```

Compared to the existing project guides: no PAT secret, no `EventListener`/`TriggerBinding`/`TriggerTemplate` to author, no webhook Route to wire up by hand — the GitHub App and PAC controller handle that.

---

## 1. Prerequisites

| Item | Notes |
|---|---|
| Cluster | Kubernetes **1.27+** with Tekton Pipelines, or OpenShift **4.10+** |
| `tkn` + `tkn-pac` CLI plugin | `tkn pac version` to confirm |
| GitHub org/repo admin rights | Needed to create/install the GitHub App |
| Two repos | `app-repo` (Java) and `deployment-repo` (Helm chart), same as the existing guides |
| Cluster admin access | To install PAC (if not already present) and create the App secret |

---

## 2. Install Pipelines as Code

**OpenShift:** installing the **Red Hat OpenShift Pipelines Operator 1.7.x or later** installs PAC automatically — no extra command. It lands in the `openshift-pipelines` namespace, and runtime config is managed through the `TektonConfig` CR's `pipelinesAsCode` section (don't hand-edit the `pipelines-as-code` ConfigMap — the operator reverts it). To disable PAC, set `enable: false` under `TektonConfig.spec.platforms.openshift.pipelinesAsCode` (field path may vary by operator version — check `oc explain tektonconfig.spec`).

**Vanilla Kubernetes / k3s:**

```bash
# stable release
kubectl apply -f https://raw.githubusercontent.com/tektoncd/pipelines-as-code/stable/release.k8s.yaml

# verify controller / webhook / watcher are all 1/1
kubectl get deployment -n pipelines-as-code
```

You then need a way for GitHub to reach the controller: either expose it with a real **Ingress** (docs show worked examples for GKE and Nginx ingress classes — `kubectl get ingress pipelines-as-code -n pipelines-as-code` once configured), or, for a quick non-internet-exposed setup, let `tkn pac bootstrap` (below) stand up a **gosmee** forwarder against `https://hook.pipelinesascode.com`.

---

## 3. Create the GitHub App

### Option A — automated (recommended)

```bash
tkn pac bootstrap
```

This installs PAC if missing (`--nightly` for the CI build instead of stable), auto-detects an OpenShift Route or asks for a Kubernetes Ingress URL (`--route-url` to override), detects the Tekton Dashboard/OpenShift console for log links, and walks you through GitHub App creation + secret generation. Use `--force-gosmee` if your cluster isn't internet-reachable and you want the gosmee forwarder instead of a real endpoint. There's also a narrower `tkn pac bootstrap github-app` subcommand that only does the App + secret step.

### Option B — manual

1. Go to `https://github.com/settings/apps` → **New GitHub App**.
2. Fill in:
   - **GitHub Application name**: e.g. `pac-java-cicd` (must be globally unique)
   - **Homepage URL**: your OpenShift console URL or any placeholder
   - **Webhook URL**: your PAC controller route/ingress
   - **Webhook secret**: `head -c 30 /dev/random | base64`
3. **Repository permissions**: Checks (Read & Write), Contents (Read & Write), Issues (Read & Write), Metadata (Read-only), Pull requests (Read & Write).
4. **Organization permissions**: Members (Read-only).
5. **Subscribe to events**: Check run, Check suite, Commit comment, Issue comment, Pull request, Push.
6. Create the app, note the **App ID**, then **Generate a private key** (downloads a `.pem`).
7. Create the cluster secret PAC reads to authenticate as the app — namespace is `pipelines-as-code` on vanilla Kubernetes, `openshift-pipelines` on OpenShift:

```bash
kubectl -n pipelines-as-code create secret generic pipelines-as-code-secret \
  --from-literal github-private-key="$(cat /path/to/private-key.pem)" \
  --from-literal github-application-id="<APP_ID>" \
  --from-literal webhook.secret="<WEBHOOK_SECRET>"
```

8. Install the App on `app-repo` (and `deployment-repo`, if the push pipeline needs to write to it) from the App's **Install App** page, scoped to just those repositories.

---

## 4. Register the Repository CRD

Tells PAC "events from this GitHub URL run PipelineRuns in this namespace":

```bash
tkn pac create repository \
  --namespace cicd-demo \
  --url https://github.com/<ORG>/app-repo
```

or apply directly. The full `spec` supports more than just `url` — the fields that matter here:

```yaml
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: app-repo
  namespace: cicd-demo
spec:
  url: "https://github.com/<ORG>/app-repo"        # required
  concurrency_limit: 1                              # max concurrent PipelineRuns for this repo
  settings:
    pipelinerun_provenance: "default_branch"        # resolve .tekton/ from main, not the PR head — avoids a fork PR shipping its own malicious pipeline
    github_app_token_scope_repos:                    # widen the installation token beyond this repo
      - "<ORG>/deployment-repo"
```

`concurrency_limit`, `git_provider` (for webhook-mode auth instead of the App), `incoming` (generic webhook triggers), and `params` (repo-level custom `{{ }}` values, optionally sourced from a Secret) are the other top-level `spec` fields, per the API reference. PipelineRuns always execute in the **namespace the Repository CR lives in**.

> `github_app_token_scope_repos` widens the per-run installation token so it can also push to `deployment-repo`; it accepts exact `org/repo` or `org/*` glob entries, and the origin repo is always included implicitly.

---

## 5. Java app repo layout

Reusing the Spring Boot demo from the existing project guide:

```
app-repo/
├── pom.xml
├── Dockerfile
├── src/
│   ├── main/java/com/example/demo/DemoApplication.java
│   └── test/java/com/example/demo/DemoApplicationTests.java
└── .tekton/
    ├── pr.yaml               # runs on pull_request → main
    ├── push.yaml             # runs on push → main
    └── tasks/
        └── update-deployment-tag.yaml   # custom Task, resolved from this same repo
```

`Dockerfile` and `pom.xml` are unchanged from the existing guide (UBI OpenJDK multi-stage build, Spring Boot Maven plugin). You can also skip hand-writing `pr.yaml` and start from `tkn pac generate` (run inside `app-repo`) — it inspects the repo (e.g. adds a lint Task if it spots a `setup.py`-style marker file for the detected language) and scaffolds a starter PipelineRun with the Git info pre-filled; edit it from there rather than starting from a blank file.

---

## 6. PR pipeline — `.tekton/pr.yaml`

Runs Maven build + test and a throwaway image build on every PR against `main`. No image push, no deployment-repo write — PRs stay side-effect-free.

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: app-repo-pull-request
  annotations:
    pipelinesascode.tekton.dev/on-event: "[pull_request]"
    pipelinesascode.tekton.dev/on-target-branch: "[main]"
    pipelinesascode.tekton.dev/task: "[git-clone, maven, buildah]"
    pipelinesascode.tekton.dev/max-keep-runs: "3"
spec:
  params:
    - name: repo_url
      value: "{{ repo_url }}"
    - name: revision
      value: "{{ revision }}"
  pipelineSpec:
    params:
      - name: repo_url
      - name: revision
    workspaces:
      - name: source
    tasks:
      - name: fetch-repository
        taskRef:
          name: git-clone
        workspaces:
          - name: output
            workspace: source
        params:
          - name: url
            value: $(params.repo_url)
          - name: revision
            value: $(params.revision)

      - name: maven-test
        runAfter: ["fetch-repository"]
        taskRef:
          name: maven
        workspaces:
          - name: source
            workspace: source
        params:
          - name: GOALS
            value: ["test"]

      - name: build-image
        runAfter: ["maven-test"]
        taskRef:
          name: buildah
        workspaces:
          - name: source
            workspace: source
        params:
          - name: IMAGE
            value: "image-registry.openshift-image-registry.svc:5000/cicd-demo/demo-app:pr-{{ pull_request_number }}"
          - name: TLSVERIFY
            value: "false"
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
```

Notes:
- `{{ repo_url }}`, `{{ revision }}`, `{{ pull_request_number }}` are PAC dynamic variables filled in from the triggering event — no TriggerBinding needed.
- The `pipelinesascode.tekton.dev/task` annotation makes PAC's resolver fetch those three Task definitions (from Tekton Hub by default) and **inline** them into one self-contained resolved PipelineRun at run time — nothing needs to be pre-installed on the cluster with `tkn hub install`.
- Only repo collaborators/org owners (or names in an `OWNERS` file, or a `pull_request` policy team on the Repository CR — see §11) can trigger a run automatically; other senders' PRs show a pending check until someone authorized comments `/ok-to-test`.

---

## 7. Push pipeline — `.tekton/push.yaml`

Runs on push to `main`: build, test, push the real image (tagged with the commit SHA), then update `deployment-repo`'s `values.yaml` — the same GitOps tag-update step as the existing Triggers-based guide, but authenticated with the GitHub App's short-lived installation token instead of a long-lived PAT.

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: app-repo-push-main
  annotations:
    pipelinesascode.tekton.dev/on-event: "[push]"
    pipelinesascode.tekton.dev/on-target-branch: "[main]"
    pipelinesascode.tekton.dev/task: "[git-clone, maven, buildah]"
    pipelinesascode.tekton.dev/task-1: "[.tekton/tasks/update-deployment-tag.yaml]"
    pipelinesascode.tekton.dev/max-keep-runs: "5"
spec:
  params:
    - name: repo_url
      value: "{{ repo_url }}"
    - name: revision
      value: "{{ revision }}"
  pipelineSpec:
    params:
      - name: repo_url
      - name: revision
    workspaces:
      - name: source
      - name: basic-auth
    tasks:
      - name: fetch-repository
        taskRef:
          name: git-clone
        workspaces:
          - name: output
            workspace: source
        params:
          - name: url
            value: $(params.repo_url)
          - name: revision
            value: $(params.revision)

      - name: maven-build
        runAfter: ["fetch-repository"]
        taskRef:
          name: maven
        workspaces:
          - name: source
            workspace: source
        params:
          - name: GOALS
            value: ["package"]

      - name: build-and-push-image
        runAfter: ["maven-build"]
        taskRef:
          name: buildah
        workspaces:
          - name: source
            workspace: source
        params:
          - name: IMAGE
            value: "image-registry.openshift-image-registry.svc:5000/cicd-demo/demo-app:$(params.revision)"

      - name: update-deployment-tag
        runAfter: ["build-and-push-image"]
        taskRef:
          name: update-deployment-tag
        workspaces:
          - name: basic-auth
            workspace: basic-auth
        params:
          - name: deployment-repo-url
            value: "https://github.com/<ORG>/deployment-repo"
          - name: image-tag
            value: "$(params.revision)"
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
    - name: basic-auth
      secret:
        secretName: "{{ git_auth_secret }}"
```

`{{ git_auth_secret }}` is a **PAC-managed Secret created per PipelineRun**, holding the GitHub App's installation token under key `git-provider-token`. By default it's scoped to the triggering repo and expires after ~8 hours; the `github_app_token_scope_repos` setting from §4 is what lets this same token also authenticate against `deployment-repo`.

---

## 8. Custom Task — `.tekton/tasks/update-deployment-tag.yaml`

Same logic as the existing guide's custom Task (clone `deployment-repo`, `yq` the `image.tag`, commit, push), just referenced via PAC's file-resolver instead of `oc apply`-installed ahead of time. Because PAC resolves it from the same commit SHA as the rest of the pipeline, Task and Pipeline changes stay atomic with the code.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: update-deployment-tag
spec:
  params:
    - name: deployment-repo-url
    - name: image-tag
  workspaces:
    - name: basic-auth
  steps:
    - name: update-and-push
      image: registry.access.redhat.com/ubi9/ubi-minimal
      env:
        - name: GITHUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: "{{ git_auth_secret }}"
              key: git-provider-token
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        microdnf install -y git yq >/dev/null
        REPO_DIR=$(mktemp -d)
        git clone "https://x-access-token:${GITHUB_TOKEN}@$(echo $(params.deployment-repo-url) | sed 's#https://##')" "$REPO_DIR"
        cd "$REPO_DIR"
        yq -i '.image.tag = "$(params.image-tag)"' charts/demo-app/values.yaml
        git config user.email "pac-bot@example.com"
        git config user.name "pac-bot"
        git commit -am "chore: bump demo-app image tag to $(params.image-tag)"
        git push origin main
```

---

## 9. Local testing before pushing

`tkn pac resolve` renders a PipelineRun exactly as PAC's controller would, without needing a real GitHub event — useful against a local Kind/CRC cluster:

```bash
tkn pac resolve -f .tekton/pr.yaml -o /tmp/pr-resolved.yaml
kubectl create -f /tmp/pr-resolved.yaml
```

Useful flags: repeatable `-f <file-or-dir>`, `-p key=value` to override a param (e.g. `-p revision=main` if you're not on the branch PAC would normally detect), `-t/--providerToken` to supply a Git provider token for private repos, `--no-secret` to skip fabricating a fake `git_auth_secret`. Make sure whatever token you pass can actually check out the repo at the resolved SHA — resolution still does a real `git-clone`.

---

## 10. End-to-end validation

1. Commit `.tekton/` and push a branch, open a PR against `main`.
2. GitHub's Checks tab shows a new check (`app-repo-pull-request`) with per-task status, name, and duration; a failing step surfaces a log snippet inline (secrets are redacted as `*****`).
3. Comment `/retest` to rerun any **failed** PipelineRuns on the PR (a no-op if everything already passed), `/retest <pipelinerun-name>` or `/test <pipelinerun-name>` to force one specific PipelineRun regardless of its last result, `/ok-to-test` (plus a commit SHA on some GitHub configurations) to let a maintainer greenlight a first-time/external contributor's PR.
4. On merge to `main`, the push pipeline runs, pushes the real image, and commits the tag bump to `deployment-repo`. If ArgoCD/Flux is watching `deployment-repo` (as in the existing guide), deployment proceeds from there automatically.
5. Tail logs any time:
   ```bash
   tkn pac logs -n cicd-demo -L
   ```
6. Inspect repo/run status:
   ```bash
   tkn pac describe -n cicd-demo app-repo
   ```

---

## 11. Restricting who can trigger CI (optional)

Beyond the OWNERS-file/collaborator default, the Repository CR supports a `policy` block:

```yaml
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: app-repo
  namespace: cicd-demo
spec:
  url: "https://github.com/<ORG>/app-repo"
  settings:
    policy:
      pull_request:      # who can auto-trigger CI on their own PRs
        - ci-users
      ok_to_test:         # who can approve CI for others via /ok-to-test, /test, /retest
        - ci-admins
```

`pull_request` and `ok_to_test` reference GitHub team slugs. This is currently supported on the GitHub App, GitHub Webhook, and Forgejo providers.

---

## 12. Troubleshooting

| Symptom | Likely cause |
|---|---|
| No Check appears on PR | GitHub App not installed on the repo, or the webhook isn't reaching the controller (check the Ingress or gosmee forwarder on non-OpenShift clusters) |
| PR comment with a YAML error | `.tekton/*.yaml` failed to parse/resolve on the cluster — PAC surfaces the Pipeline Controller's error directly in the GitHub UI |
| PR stuck on a "pending" check | Sender isn't a collaborator/org owner, isn't in an `OWNERS` file, and isn't covered by a `pull_request` policy team — needs someone authorized to comment `/ok-to-test` |
| `update-deployment-tag` push fails with 403 | `{{ git_auth_secret }}` is scoped only to `app-repo` by default — add `deployment-repo` to `github_app_token_scope_repos` on the Repository CR (§4) |
| Task not found during resolution | Name in `pipelinesascode.tekton.dev/task` doesn't match a Tekton Hub entry for your PAC's configured hub/catalog, or the relative path for a same-repo Task is wrong |

---

## 13. How this differs from the existing Triggers-based guide

| | Triggers-based (existing guides) | Pipelines as Code |
|---|---|---|
| GitHub auth | Long-lived PAT in a cluster Secret | GitHub App, short-lived installation tokens (~8h) |
| Event routing | Manual `EventListener` + exposed Route/Ingress + `TriggerBinding`/`TriggerTemplate` | GitHub App webhook → PAC controller; no TriggerBinding/Template to write |
| Pipeline location | Applied ahead of time with `oc apply` | Committed in `.tekton/` in the app repo, versioned with the code |
| Task installation | `tkn hub install task ...` beforehand | Resolved and inlined automatically per-run via `pipelinesascode.tekton.dev/task` annotations |
| PR feedback | Nothing built-in — wired up yourself | Native GitHub Checks tab (per-task status + log snippets) + PR comments + `/retest`, `/test`, `/ok-to-test` |
| Access control | Whatever you build around the webhook | Built-in collaborator/OWNERS default, or explicit `policy.pull_request` / `policy.ok_to_test` teams |
| Underlying engine | Tekton Pipelines + Tekton Triggers | Tekton Pipelines (Triggers not needed) |

---

## Sources

- [Getting Started](https://pipelinesascode.com/docs/getting-started/)
- [Installation Overview](https://pipelinesascode.com/docs/installation/overview/)
- [Installing on Kubernetes](https://pipelinesascode.com/docs/installation/kubernetes/)
- [Installing on OpenShift](https://pipelinesascode.com/docs/installation/openshift/)
- [GitHub App provider setup](https://pipelinesascode.com/docs/providers/github-app/)
- [Repository CRD guide](https://pipelinesascode.com/docs/guides/repository-crd/)
- [Repository spec API reference](https://pipelinesascode.com/docs/api/repository-spec/)
- [GitHub token scoping](https://pipelinesascode.com/docs/guides/repository-crd/github-token-scoping/)
- [Creating pipelines / GitHub token usage](https://pipelinesascode.com/docs/guides/creating-pipelines/github-token/)
- [Event matching](https://pipelinesascode.com/docs/guides/event-matching/)
- [Pipeline/Task resolution](https://pipelinesascode.com/docs/guides/pipeline-resolution/)
- [Running pipelines / statuses](https://pipelinesascode.com/docs/guides/statuses/)
- [GitOps commands](https://pipelinesascode.com/docs/guides/gitops-commands/)
- [Policy authorization](https://pipelinesascode.com/docs/advanced/policy-authorization/)
- [CLI: bootstrap](https://pipelinesascode.com/docs/cli/bootstrap/) · [resolve](https://pipelinesascode.com/docs/cli/resolve/) · [generate](https://pipelinesascode.com/docs/cli/generate/)
