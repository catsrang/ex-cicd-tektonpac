# Implementation Guide: Tekton Pipelines-as-Code CI/CD Example

Step-by-step guide to reproduce this repo's setup from scratch, with the
exact verification command **and real expected output** for every step —
pulled from this project's actual implementation run, not invented.
Written after actually doing it once (see
`topic/20260820-1_init_tekton_cicd_example/30.impl.md` for the
chronological log with every wrong turn); this guide gives you the
*correct* path directly, with the real gotchas called out where they'd
otherwise bite you.

Every verification below follows the same three-part shape:
**Command → Expected output (real example) → If it fails.** Don't
consider a step done because the command *ran without error* — confirm
the output actually matches, and if it doesn't, use the "If it fails"
line to find the matching Gotcha before moving on.

## Architecture

```
[Developer] --push/PR--> [GitHub: app-repo]
                              |  webhook (GitHub App)
                              v
                 [PAC controller/webhook/watcher on cluster]
                              |  resolves .tekton/*.yaml + Tasks
                              v
                      [PipelineRun in cicd-demo namespace]
                              |
        pr.yaml: git-clone -> maven test -> buildah build (no push)
        push.yaml: git-clone -> maven package -> buildah build+push -> update-deployment-tag
                              |                                            |
                              v                                            v
                  [ghcr.io/<owner>/demo-app]                [GitHub: deployment-repo
                                                               values.yaml image.tag bumped]
```

Two GitHub repos (`app-repo` = this repo, `deployment-repo` = GitOps
target), one GitHub App, one PAC install, one `cicd-demo` namespace.

## Prerequisites

- A Kubernetes/k3s cluster with **Tekton Pipelines** already installed.
- `kubectl` pointed at that cluster.
- `tkn` + `tkn-pac` CLI (`tkn-pac bootstrap` needs it; you can install
  manually without it, but it's much more painful).
- `gh` CLI, authenticated (`gh auth login`, then `gh auth status` to
  confirm — a stale/invalid token is a common failure mode, see
  Gotcha #0 below).
- A domain/Ingress (or `gosmee`) so GitHub can reach the cluster.
- Two empty GitHub repos: `app-repo` and `deployment-repo`.

---

## Progress checklist

Track completion at a glance; each box maps to a numbered step below and
is only checked when its **verification** passes, not just when its
commands run without error.

- [ ] **Step 1** — PAC controller/webhook/watcher installed, all `1/1` healthy
- [ ] **Step 2** — Public HTTPS endpoint reaches the controller (`200` from *outside* the cluster)
- [ ] **Step 3** — GitHub App exists; `pipelines-as-code-secret` has all 3 keys
- [ ] **Step 3a** (Gotcha #1) — App's repo-access list contains **both** repos, confirmed by a live webhook test, not just the settings page
- [ ] **Step 4** — `deployment-repo` has a `main` branch with the chart skeleton pushed
- [ ] **Step 5** — **Both** `Repository` CRs applied and `tkn pac describe` resolves cleanly
- [ ] **Step 5a** (Gotchas #2/#3) — a real event shows `"Github token scope extended to [...]"`, not a `failed to scope` error
- [ ] **Step 6** — `mvn test` and `docker build` both succeed locally, independent of any pipeline
- [ ] **Step 7** — `.tekton/*.yaml` pass `--dry-run=client` and `tkn pac resolve`
- [ ] **Step 8** — `ghcr-credentials` Secret exists with key `config.json`, built from a `write:packages`-scoped PAT
- [ ] **Step 9** — Local dry run: `pr.yaml` completes (`{{ pull_request_number }}` aside); `push.yaml` fails only for an expected/understood reason
- [ ] **Step 10** — Real PR passes Checks, `/retest` behaves correctly, merge triggers the push pipeline, and the GHCR image + `deployment-repo` commit are independently confirmed

---

## Step 1 — Install PAC on the cluster

- [ ] Apply the release manifest
- [ ] Wait for all three deployments to become `Available`

```bash
kubectl apply -f https://raw.githubusercontent.com/tektoncd/pipelines-as-code/stable/release.k8s.yaml
kubectl -n pipelines-as-code wait --for=condition=Available --timeout=180s deployment --all
```

**Verify:**
```bash
kubectl get deployment -n pipelines-as-code
```
**Expected output** (all `READY` columns matching, `1/1`):
```
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
pipelines-as-code-controller    1/1     1            1           8h
pipelines-as-code-watcher       1/1     1            1           8h
pipelines-as-code-webhook       1/1     1            1           8h
```
```bash
kubectl get pods -n pipelines-as-code
```
**Expected**: three pods, `STATUS Running`, `RESTARTS 0`.

**If it fails:** a deployment stuck below `1/1` for more than a minute or
two usually means an image pull problem or a resource constraint — check
`kubectl describe deployment <name> -n pipelines-as-code` and
`kubectl get events -n pipelines-as-code --sort-by=.lastTimestamp` for
the actual reason rather than re-running `apply`.

---

## Step 2 — Expose the controller to GitHub

- [ ] Decide Ingress vs. `gosmee`
- [ ] Apply the Ingress (if chosen) — reuse an existing host with a
      specific path prefix if you already have one, rather than
      provisioning new DNS/TLS
- [ ] Confirm the path doesn't shadow anything else already on that host

You need a public HTTPS endpoint pointing at
`pipelines-as-code-controller:8080` in the `pipelines-as-code` namespace.
Two options:

- **Real Ingress** (what this repo uses) — if your cluster already has a
  reachable Ingress for something else (a dashboard, etc.), you can share
  the same host with a more specific path prefix; the controller doesn't
  care about the path at all.
- **`gosmee` forwarder** — no public endpoint needed, good for a
  non-internet-reachable dev cluster. `tkn-pac bootstrap` can set this up
  for you with `--force-gosmee`.

Example Ingress (`infra/pac/ingress.yaml` in this repo):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pipelines-as-code-controller
  namespace: pipelines-as-code
spec:
  ingressClassName: <your-ingress-class>
  rules:
    - host: <your-host>
      http:
        paths:
          - path: /pac
            pathType: Prefix
            backend:
              service:
                name: pipelines-as-code-controller
                port:
                  number: 8080
```

**Verify (from *outside* the cluster, not `kubectl port-forward`):**
```bash
curl -sk -o /dev/null -w "%{http_code}\n" -X POST https://<your-host>/pac
curl -sk -o /dev/null -w "%{http_code}\n" https://<your-host>/
```
**Expected output** (real example from this project — `/pac` reaches the
controller, `/` still reaches whatever else was already on that host,
unaffected):
```
200
401
```
(The `401` here was Traefik's own basicauth on an existing dashboard
route — the point of this second check is confirming your new path
*didn't* shadow or break whatever was already there, whatever its actual
expected status is on your setup.)

**If it fails:**
- `000` / connection refused — check `kubectl get ingress -n
  pipelines-as-code` exists and the DNS/external IP actually resolves.
- A TLS error from plain `curl` (no `-k`) with no `-k` flag — that's
  expected if there's no cert-manager (self-signed cert); not a real
  failure, just needs `-k`/`--insecure` for local testing. **You'll still
  need to disable "SSL verification" on the GitHub App's webhook settings
  (Step 3)**, or every *real* webhook delivery from GitHub will fail TLS
  verification (GitHub doesn't have a `-k` equivalent).
- `404` — your Ingress `path`/`pathType` doesn't match what you're
  curling; double check `Prefix` vs `Exact`.

---

## Step 3 — Create the GitHub App

- [ ] Run `tkn-pac bootstrap github-app` (or the manual App-creation flow)
- [ ] Confirm the cluster secret has all 3 expected keys
- [ ] Disable "SSL verification" on the App's webhook settings if using a self-signed cert
- [ ] **Do not install the App yet** — read Gotcha #1 first, then install once, correctly

**Automated (recommended):**
```bash
tkn-pac bootstrap github-app \
  --route-url https://<your-host>/pac \
  --skip-install \
  --github-application-name <globally-unique-name>
```
`--skip-install` since PAC's already installed (Step 1). This opens a
local relay page; click through to GitHub's App-manifest flow, click
**Create GitHub App**. It creates the App *and* the cluster secret in one
shot.

**Verify the secret exists with the right keys:**
```bash
kubectl -n pipelines-as-code describe secret pipelines-as-code-secret
```
**Expected output** (key names and sizes only — this is deliberately the
safe command, see the warning below):
```
Name:         pipelines-as-code-secret
Namespace:    pipelines-as-code
Type:  Opaque

Data
====
github-application-id:  6 bytes
github-private-key:     1704 bytes
webhook.secret:         44 bytes
```
(Exact byte counts will differ — what matters is all three keys being
present and non-zero.)

> ⚠️ **Don't verify the secret's *values*** with something like
> `kubectl get secret pipelines-as-code-secret -n pipelines-as-code -o jsonpath='{.data}'`
> — that prints the full base64-encoded private key into whatever
> log/terminal you're in. `describe` (above) is the safe form: key names
> and sizes, never values.

**If it fails:** `kubectl get secret pipelines-as-code-secret -n
pipelines-as-code` returning `NotFound` after `bootstrap` reports success
usually means the bootstrap flow was cancelled partway through the
browser step — rerun it; it's idempotent.

---

## ⚠️ Gotcha #1 (the big one) — Install the App on **both** repos in the *same* step

This is the single most time-consuming bug in the whole implementation:
GitHub Apps are installed with a repo-access list (`All repositories` or
`Only select repositories`). When you go back later to *add* a second
repo to an existing installation (Settings → Applications → your App →
**Configure** → Select repositories), it's easy to end up with the list
containing only the newly-added repo — silently dropping the first one.
When that happens, GitHub simply **never sends webhooks for the dropped
repo again** — no error, no warning, nothing in "Recent Deliveries" for
that repo at all. It looks exactly like the App working fine (it still
shows "installed" on the repo's own installations page) except events
just never arrive.

**Do this instead:** before installing the App anywhere, decide the full
set of repos it needs (both `app-repo` and `deployment-repo`), and select
**both** in the same visit to the repo-access configuration, whether
that's the first install or an update to an existing one.

- [ ] Both repos appear under "Repository access" on the same installation
- [ ] A live push actually produces controller log activity (not just a
      "200" on the App's own delivery-history page)

**Verify — step 1, config check:**
1. Go to `https://github.com/settings/installations` → **Configure** next
   to your App.
2. Under "Repository access", confirm **both** repos are listed (or "All
   repositories" is selected).

**Verify — step 2, the definitive functional test:**
```bash
kubectl logs -n pipelines-as-code -l app.kubernetes.io/name=pipelines-as-code-controller -f --since=1s
```
then, in another terminal, push a trivial commit to `app-repo`.

**Expected output** (real example — a genuine `push` event landing
within seconds):
```json
{"level":"info","caller":"github/github.go:353","msg":"github-app: initialized OAuth2 client for providerName=github providerURL=","event-type":"push","source-repo-url":"https://github.com/<org>/<app-repo>","target-branch":"refs/heads/main"}
```
Any `event-type` field appearing at all (`push`, `pull_request`, etc.)
means the webhook reached the controller and started processing.

**If it fails (this is the actual symptom of the bug):** total silence in
the log — nothing at all, not even an error — while the App's "Recent
Deliveries" page shows `200` responses for *other*, older event types
(`ping`, `installation.created`, an unrelated repo's `push`). That
combination — real 200s in the delivery log, but none for the repo/event
you just triggered, and zero controller-side log activity — is this
gotcha, not a connectivity or Ingress problem (verify Step 2 is still
fine separately if you're unsure). Fix the repo-access list, re-push, and
re-check.

---

## Step 4 — Create `deployment-repo`

- [ ] Clone the empty repo
- [ ] Add the minimal Helm chart skeleton
- [ ] Push to `main`
- [ ] Install the App here too (same sitting as Step 3 — see Gotcha #1)

```bash
git clone git@github.com:<org>/<deployment-repo>.git
cd <deployment-repo>
mkdir -p charts/demo-app
cat > charts/demo-app/Chart.yaml <<'EOF'
apiVersion: v2
name: demo-app
type: application
version: 0.1.0
appVersion: "placeholder"
EOF
cat > charts/demo-app/values.yaml <<'EOF'
image:
  tag: "placeholder"
EOF
git add . && git commit -m "Add minimal demo-app Helm chart skeleton" && git push -u origin main
```

**Verify:**
```bash
git ls-remote git@github.com:<org>/<deployment-repo>.git
```
**Expected output** (a ref for `main`, not empty — compare against
`git ls-remote` *before* this step, which should have printed nothing at
all for a genuinely empty repo):
```
a1b2c3d4e5f6...    refs/heads/main
```

**If it fails:** empty output after pushing means the push itself didn't
land — check `git push` actually reported `main -> main` and not a
rejected/failed push (e.g. no write access yet — see Gotcha #0 for `gh`
auth, or confirm your SSH key is registered with `ssh -T git@github.com`).

---

## Step 5 — Register `Repository` CRs — **for both repos**

- [ ] Create the `cicd-demo` namespace
- [ ] Apply `app-repo`'s `Repository` CR
- [ ] Apply `deployment-repo`'s `Repository` CR (see Gotcha #2 — not optional)

```yaml
# app-repo's Repository CR
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: app-repo
  namespace: cicd-demo
spec:
  url: "https://github.com/<org>/<app-repo>"
  settings:
    pipelinerun_provenance: default_branch   # resolve .tekton/ from main, not the PR head — security default
    github_app_token_scope_repos:
      - "<org>/<deployment-repo>"
```

```yaml
# deployment-repo's Repository CR — see Gotcha #2, this is NOT optional
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: deployment-repo
  namespace: cicd-demo
spec:
  url: "https://github.com/<org>/<deployment-repo>"
```

```bash
kubectl create namespace cicd-demo
kubectl apply -f app-repo-repository.yaml
kubectl apply -f deployment-repo-repository.yaml
```

**Verify:**
```bash
tkn-pac describe -n cicd-demo <app-repo-name>
```
**Expected output** (real example, before any run has happened yet):
```
Name:        app-repo
Namespace:   cicd-demo
URL:         https://github.com/<org>/<app-repo>

No runs has started.
```
```bash
kubectl get repository -n cicd-demo
```
**Expected**: both CRs listed with their URLs:
```
NAME              URL
app-repo          https://github.com/<org>/<app-repo>
deployment-repo   https://github.com/<org>/<deployment-repo>
```

**If it fails:** `tkn-pac describe` erroring with "no repository found"
means either the CR wasn't applied to `cicd-demo` specifically, or the
name/namespace you passed doesn't match `metadata.name`/
`metadata.namespace` in the YAML — `kubectl get repository -A` to find
where it actually landed.

---

## ⚠️ Gotcha #2 — `github_app_token_scope_repos` needs the scoped repo to have its own `Repository` CR

If you skip creating a `Repository` CR for `deployment-repo` (thinking
it's not needed since it doesn't trigger its own pipelines), every event
on `app-repo` will fail with:
```
failed to scope GitHub token as repo with pattern <org>/<deployment-repo>
does not exist in namespace cicd-demo
```
The CR doesn't need any `.tekton/` files in that repo to back it — it
exists purely to satisfy this validation. This is what Step 5's second
CR is for.

## ⚠️ Gotcha #3 — Cluster-wide flag also gates cross-repo token scoping

Even with Gotcha #2 fixed, you may hit:
```
failed to scope GitHub token as repo scoped key secret-github-app-token-scoped
is enabled. Hint: update key secret-github-app-token-scoped from
pipelines-as-code configmap to false
```
The `pipelines-as-code` ConfigMap's `secret-github-app-token-scoped` key
defaults to `"true"`, which — counter-intuitively — **restricts** the
token to only the originating repo and blocks
`github_app_token_scope_repos` from working at all. Fix:
```bash
kubectl patch configmap pipelines-as-code -n pipelines-as-code \
  --type=merge -p '{"data":{"secret-github-app-token-scoped":"false"}}'
```
This is cluster-wide (affects every repo on this PAC install — fine on a
single-project cluster, worth double-checking on a shared one). The
controller live-reloads it, no restart needed — confirm via:
```bash
kubectl logs -n pipelines-as-code -l app.kubernetes.io/name=pipelines-as-code-controller --since=30s
```
**Expected**: `"msg":"updating value for field SecretGHAppRepoScoped: from 'true' to 'false'"`
within a few seconds of patching, with no pod restart.

**Verify both Gotcha #2 and #3 fixes together** — push any commit and
check the controller logs (same command as Gotcha #1's verification):
```bash
kubectl logs -n pipelines-as-code -l app.kubernetes.io/name=pipelines-as-code-controller -f --since=1s
```
**Expected output** (real example):
```json
{"level":"info","caller":"github/scope.go:108","msg":"Github token scope extended to [<org>/<deployment-repo> <org>/<app-repo>] "}
```
**If it fails:** any `"msg":"failed to scope ..."` line at this point
means one of the two gotchas above isn't actually fixed yet — re-check
`kubectl get repository -n cicd-demo` (Gotcha #2) and `kubectl get
configmap pipelines-as-code -n pipelines-as-code -o
jsonpath='{.data.secret-github-app-token-scoped}'` (Gotcha #3, should
print `false`) before assuming it's something else.

---

## Step 6 — Scaffold the app

- [ ] Standard Maven/Spring Boot layout (`pom.xml`, source, test, `Dockerfile`)
- [ ] `mvn test` passes locally
- [ ] `docker build` (or `podman build`) succeeds locally

Standard Maven/Spring Boot layout — nothing PAC-specific here. Minimal:
`pom.xml`, `src/main/java/.../Application.java`,
`src/test/java/.../ApplicationTests.java`, `Dockerfile`.

**Verify:**
```bash
mvn test
```
**Expected output** (real example — Spring context loads, test passes,
build ends green with no `mvn` failure summary):
```
  .   ____          _            __ _ _
 /\\ / ___'_ __ _ _(_)_ __  __ _ \ \ \ \
( ( )\___ | '_ | '_| | '_ \/ _` | \ \ \ \
 \\/  ___)| |_)| | | | | || (_| |  ) ) ) )
  '  |____| .__|_| |_|_| |_\__, | / / / /
 =========|_|==============|___/=/_/_/_/
 :: Spring Boot ::                (v3.2.5)

INFO ... Starting DemoApplicationTests using Java 17...
INFO ... Started DemoApplicationTests in 0.481 seconds (process running for 0.741)
```
No `[ERROR]`/`BUILD FAILURE` output, and the process exits `0`.

```bash
docker build -t demo-app .   # or: podman build -t demo-app .
```
**Expected**: image builds through both stages (`build` and the runtime
stage) and ends with `Successfully tagged demo-app:latest` (Docker) or
equivalent success output (Podman).

**If it fails:** a `mvn test` failure here is a real app bug — fix it
before touching any pipeline YAML; a pipeline will only ever reproduce
what `mvn test` already does locally, it can't fix a broken test. A
`docker build` failure at the `mvn -B -DskipTests package` step inside
the Dockerfile most often means a Java-version mismatch between your
local `mvn test` environment and the build stage's base image — check
`java -version` locally against the Dockerfile's `FROM` tag.

---

## Step 7 — Write `.tekton/` pipeline definitions

- [ ] Confirm which Task catalog this cluster's PAC actually resolves from
- [ ] Fetch and read the *actual* Task YAMLs (not a guide's example) for
      required workspaces/params
- [ ] Write `pr.yaml`, `push.yaml`, and the custom `update-deployment-tag` Task
- [ ] Structural validation passes (`--dry-run=client`)
- [ ] Resolution succeeds (`tkn pac resolve`)

Before writing `IMAGE` params, **check which catalog your cluster's PAC
actually resolves Tasks from** — don't assume it's `hub.tekton.dev`:
```bash
kubectl get configmap pipelines-as-code -n pipelines-as-code -o jsonpath='{.data.hub-url}'
```
**Expected output** (real example — newer PAC versions default here, not
to the older `hub.tekton.dev` API many guides still assume):
```
https://artifacthub.io
```

Fetch the real Task definitions from there (or from the `tektoncd/catalog`
repo the Artifact Hub package points to) and check their actual `params`/
`workspaces` before writing your `.tekton/*.yaml` — don't trust a guide's
example verbatim. Two things worth checking specifically:

- Does the `maven` Task require a `maven-settings` workspace? (The
  common `tektoncd/catalog` v0.4 one does, and it's *not* optional — omit
  it and your PipelineRun fails at workspace-binding time. An `emptyDir`
  workspace is enough; the Task generates a default `settings.xml` if the
  workspace is empty.)
- Does the `buildah` Task have a `SKIP_PUSH` param? (Cleaner than the
  common "point at an unreachable registry" trick for a no-push PR
  pipeline — check before copying an older recipe's workaround.)

**`pr.yaml`** — `pull_request` → `main`: `git-clone` → `maven test` →
`buildah` build with `SKIP_PUSH: "true"`.

**`push.yaml`** — `push` → `main`: `git-clone` → `maven package` →
`buildah` build+push → custom `update-deployment-tag` Task. The `buildah`
step needs a `dockerconfig` workspace bound to a registry-credentials
Secret (Step 8) for the push to actually work.

**Verify structurally, before any cluster access is even needed:**
```bash
kubectl apply --dry-run=client -f .tekton/pr.yaml
kubectl apply --dry-run=client -f .tekton/push.yaml
kubectl apply --dry-run=client -f .tekton/tasks/update-deployment-tag.yaml
```
**Expected output** (real example, one line per file, `(dry run)` suffix):
```
pipelinerun.tekton.dev/app-repo-pull-request created (dry run)
pipelinerun.tekton.dev/app-repo-push-main created (dry run)
task.tekton.dev/update-deployment-tag created (dry run)
```

**Verify resolution** (needs `tkn-pac` and repo push access — you can run
this after Step 9's initial push):
```bash
tkn-pac resolve -f .tekton/pr.yaml -o /tmp/pr-resolved.yaml
grep -c "taskSpec:" /tmp/pr-resolved.yaml
```
**Expected**: a number greater than `0` (real inlined Task specs, not
stub references) and the command itself prints `PipelineRun has been
written to /tmp/pr-resolved.yaml` with no error.
```bash
tkn-pac resolve --no-secret -f .tekton/push.yaml -o /tmp/push-resolved.yaml
```
`--no-secret` avoids an interactive prompt when `{{ git_auth_secret }}`
is detected in the template.

**If it fails:** `kubectl apply --dry-run=client` rejecting a file with a
schema error means a typo or wrong field name in your YAML — the error
message names the exact field. `tkn-pac resolve` failing with something
like `task <name> not found` means the Task name in your
`pipelinesascode.tekton.dev/task` annotation doesn't match what's
actually in your cluster's configured catalog (re-check the `hub-url`
lookup above).

---

## ⚠️ Gotcha #4 — `{{ git_auth_secret }}` doesn't substitute inside an inlined custom Task's `env`

A common custom-Task pattern for authenticating to a second repo:
```yaml
env:
  - name: GITHUB_TOKEN
    valueFrom:
      secretKeyRef:
        name: "{{ git_auth_secret }}"
        key: git-provider-token
```
**This doesn't work.** PAC's `{{ }}` substitution reaches known top-level
`PipelineRun` fields (like the `workspaces:` block's `secretName:`) but
not arbitrary text inside a custom Task that got inlined via the
`pipelinesascode.tekton.dev/task-1` (same-repo relative path) mechanism.
The literal string `"{{ git_auth_secret }}"` ends up in the pod spec and
gets rejected by Kubernetes' name validation.

**Symptom (real example):**
```
failed to create task run pod "...": Pod "...-pod" is invalid:
spec.containers[0].env[0].valueFrom.secretKeyRef.name: Invalid value:
"{{ git_auth_secret }}": a lowercase RFC 1123 subdomain must consist of
lower case alphanumeric characters, '-' or '.', ...
```

**Fix:** bind the git-auth Secret as a **workspace** instead (this
substitution path does work) and read the token from the mounted file:
```yaml
workspaces:
  - name: basic-auth
steps:
  - name: update-and-push
    script: |
      GITHUB_TOKEN=$(cat "$(workspaces.basic-auth.path)/git-provider-token")
      ...
```
The generated secret (bound to the `basic-auth` workspace, itself
resolved from `{{ git_auth_secret }}` at the PipelineRun's top level —
where substitution *does* work) has keys `.git-credentials`, `.gitconfig`,
and `git-provider-token`; the last one is the plain token you want.

**Verify:**
```bash
kubectl describe secret <pac-gitauth-*> -n cicd-demo
```
(name varies per run — find it with `kubectl get secret -n cicd-demo -l app.kubernetes.io/managed-by=pipelinesascode.tekton.dev`)

**Expected output** (real example — key names only, never values):
```
Data
====
.git-credentials:    90 bytes
.gitconfig:          51 bytes
git-provider-token:  40 bytes
```

## ⚠️ Gotcha #5 — `yq` isn't a `microdnf` package on UBI minimal images

```bash
microdnf install -y git yq
```
**Symptom (real example):**
```
error: No package matches 'yq'
```
Because `microdnf` resolves the whole install atomically, this also means
`git` silently never got installed either. Fix: install `git` alone,
download a **pinned-version** static `yq` binary directly:
```bash
microdnf install -y git
curl -sL "https://github.com/mikefarah/yq/releases/download/v4.53.4/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
```
(Check your node's architecture first — `kubectl get nodes -o
custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture` —
and swap `amd64` for `arm64` if needed.)

> **Pin the version, don't use `/releases/latest/download/...`.** This
> Task carries git-push credentials to `deployment-repo`; a `latest` URL
> means every real pipeline run downloads and executes whatever the
> upstream project happens to have tagged as latest *at that moment*, with
> no review and no way to know what changed between two runs. Pin an
> explicit release tag (bump it deliberately, like any other dependency),
> and check https://github.com/mikefarah/yq/releases for the current tag
> when setting this up rather than reusing an old pin indefinitely.

Related: **don't** also `microdnf install curl` on top of this — UBI
minimal ships `curl-minimal` by default, and installing the full `curl`
package conflicts with it:
```
Problem: problem with installed package curl-minimal-7.76.1-...x86_64
 - package curl-minimal-... conflicts with curl provided by curl-...
```
`curl-minimal` already provides what you need.

**Verify the whole Task end-to-end** once wired into `push.yaml` (see
Step 9/10) — a `TaskRun` named `...-update-deployment-tag` reaching
`Succeeded` is the real confirmation; its logs should show `yq -i`
running with no `microdnf`/`curl` errors above it.

---

## Step 8 — Create the registry credentials Secret

- [ ] Issue a PAT scoped to `write:packages`
- [ ] Build a `config.json` locally (never through a chat/log channel)
- [ ] Create the Secret with the exact key name the `buildah` Task expects
- [ ] Delete the local temp file

```bash
# Build a docker config.json (do this locally, never paste a real
# token into a chat/logging tool — see the Security Notes section)
cat > /tmp/config.json <<EOF
{"auths":{"ghcr.io":{"auth":"$(printf '%s' "<username>:<PAT>" | base64)"}}}
EOF

kubectl create secret generic ghcr-credentials \
  --from-file=config.json=/tmp/config.json \
  -n cicd-demo

rm -f /tmp/config.json
```

## ⚠️ Gotcha #6 — the Secret's key must be literally `config.json`, not `.dockerconfigjson`

`kubectl create secret docker-registry` is the "obvious" command for
registry credentials, but it stores the file under a `.dockerconfigjson`
key. Check what your actual `buildah` Task script does with the
`dockerconfig` workspace first — the common one sets `DOCKER_CONFIG` to
the workspace path and lets `buildah`/`skopeo` look for `config.json`
there, which needs the generic-secret + explicit-key-name approach above,
not `create secret docker-registry`.

The PAT needs the **`write:packages`** scope specifically — a token with
only `repo`/`workflow` will create the Secret fine (no error at this
step) but fail much later, at the actual push:
```
Error: pushing image "ghcr.io/<owner>/<image>:<tag>" to "docker://...":
writing blob: initiating layer upload to /v2/.../blobs/uploads/ in
ghcr.io: denied: permission_denied: The token provided does not match
expected scopes.
```

**Verify the key name:**
```bash
kubectl get secret ghcr-credentials -n cicd-demo -o jsonpath='{.data}' | \
  python3 -c "import json,sys; print(list(json.load(sys.stdin).keys()))"
```
**Expected output:**
```
['config.json']
```
**Verify the token's actual scopes** before trusting it, without ever
printing the token itself:
```bash
curl -s -o /dev/null -D - -H "Authorization: token $TOKEN" https://api.github.com/user | grep -i x-oauth-scopes
```
**Expected output** (must include `write:packages`):
```
x-oauth-scopes: repo, workflow, write:packages
```
**If it fails:** scopes header missing `write:packages` — don't proceed
to a real push with it; issue a new PAT with the right scope and re-run
Step 8's secret-creation command with the new value (`kubectl create
secret ... --dry-run=client -o yaml | kubectl apply -f -` to update it in
place).

---

## Step 9 — Local dry run

- [ ] Commit and push everything to `main` first
- [ ] `pr.yaml`: resolve, apply, watch — expect success except one known,
      inherent local-testing limitation
- [ ] `push.yaml`: resolve, apply, watch — expect either full success or
      a specific, understood failure, not a mystery

Commit and push everything to `main` first — `git-clone` needs real
content to fetch, and `pipelinerun_provenance: default_branch` means PAC
resolves `.tekton/` from whatever's actually on `main`.

```bash
tkn-pac resolve -f .tekton/pr.yaml -o /tmp/pr-resolved.yaml
kubectl create -f /tmp/pr-resolved.yaml -n cicd-demo
kubectl get pipelinerun -n cicd-demo -w
```

**Expected**: `fetch-repository` and `maven-test` (or `maven-build`)
**Succeeded**. The `buildah` step, *if* its `IMAGE` param uses
`{{ pull_request_number }}`, will fail — real example:
```
Error: tag ghcr.io/<owner>/demo-app:pr-{{ pull_request_number }}: invalid reference format
```
This is expected and not a bug: that variable is only populated by a
real GitHub PR webhook event; `tkn-pac resolve` has no PR context to fill
it with locally (see Gotcha #9 below). It'll resolve correctly once a
real PR triggers it (Step 10). You can isolate/confirm the rest of the
chain by substituting a placeholder value into the *local resolved copy
only* (never the committed `.tekton/pr.yaml`) and re-applying — real
result from doing exactly this in this project: all three tasks
succeeded once a valid tag was supplied.

For `push.yaml`, the acceptable local-testing outcome is: resolves
without error, and *either* runs to completion (if you've already
supplied real credentials via `tkn-pac resolve -t <token>`) *or* fails
for an expected/understood reason (missing registry creds, missing
`git_auth_secret`) — don't force it past that point with a fake secret
just to see green.

**Verify a `push.yaml` PipelineRun's terminal state, whichever it is:**
```bash
kubectl get pipelinerun -n cicd-demo <name>
kubectl get taskrun -n cicd-demo -l tekton.dev/pipelineRun=<name>
kubectl logs -n cicd-demo -l tekton.dev/pipelineTask=<failing-task>,tekton.dev/pipelineRun=<name> --all-containers=true
```
**Expected output shape** (real example of a *partial* run — the first
two tasks genuinely completed, only the credential-dependent step is
blocked):
```
NAME                                                Succeeded   Reason
...-fetch-repository                                True        Succeeded
...-maven-build                                     True        Succeeded
...-build-and-push-image                            False       Failed
```

> ⚠️ If a task-run pod gets stuck `Pending` forever instead of cleanly
> `Failed`, check:
> ```bash
> kubectl describe pod <pod> -n cicd-demo
> ```
> **Expected symptom text** if this is the coschedule-workspaces
> behavior: `FailedMount ... secret "<name>" not found` — some Tekton
> versions with `Coschedule: workspaces` enabled require *all*
> PipelineRun-level workspace secrets to exist before *any* task's pod
> can start, not just the task that binds them. `kubectl delete
> pipelinerun <name> -n cicd-demo` to clean up a stuck run once you
> understand why.

---

## Step 10 — Real end-to-end validation

- [ ] Open a real PR with a small, real change
- [ ] Confirm the PR pipeline fires and passes on GitHub's own Checks tab
- [ ] Exercise a GitOps command (`/retest`) and confirm the *correct*
      behavior, which may be a deliberate no-op
- [ ] Merge and confirm the push pipeline fires
- [ ] Independently verify the real-world side effects — don't trust the
      green PipelineRun status alone
- [ ] Confirm reproducibility with a second, independent trigger

```bash
git checkout -b test-branch
# make a small real change
git push -u origin test-branch
gh pr create --base main --head test-branch --title "..." --body "..."
```

**Verify the PR pipeline fired for real:**
```bash
gh pr checks <PR-number>
```
**Expected output** (real example):
```
Pipelines as Code CI / app-repo-pull-request    pass    1m9s    https://...
```
**If it fails / nothing appears after ~30s:** don't assume it's still
"processing" — silence here is the signature of Gotcha #1 specifically,
not of slowness. Go straight to that gotcha's verification steps
(controller log tail + a fresh trivial commit) rather than waiting
longer.

**Exercise a GitOps command:**
```bash
gh pr comment <PR-number> --body "/retest"
```
**Expected** on an already-passing PR (real example from the controller
log):
```
"msg":"All PipelineRuns for this commit have already succeeded. Use
`/retest <pipeline-name>` to re-run a specific pipeline or `/test` to
re-run all pipelines."
```
This is success — the correct, intentional no-op — not a failed trigger.
If you want to force a duplicate run to confirm the mechanism end-to-end
some other way, use `/test` (re-runs everything) or `/retest
<specific-pipeline-name>`.

**Merge and verify the push pipeline:**
```bash
gh pr merge <PR-number> --merge --delete-branch
```
```bash
kubectl get pipelinerun -n cicd-demo -w
```
**Expected**: a new PipelineRun matching your push pipeline's name
appears within seconds and all four tasks (`fetch-repository`,
`maven-build`/`maven-package`, `build-and-push-image`,
`update-deployment-tag`) reach `Succeeded`.

**Verify independently — don't just trust the green PipelineRun status:**
```bash
# 1. Real image in the registry
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/users/<owner>/packages/container/<image>/versions" | \
  python3 -c "import json,sys; [print(v['metadata']['container']['tags']) for v in json.load(sys.stdin)[:3]]"
```
**Expected**: the merge commit's SHA appears as a tag in the printed
list.
```bash
# 2. Real commit in deployment-repo — clone fresh, don't reuse the Task's own working copy
git clone git@github.com:<org>/<deployment-repo>.git /tmp/verify
cat /tmp/verify/charts/demo-app/values.yaml
git -C /tmp/verify log --oneline -3
rm -rf /tmp/verify
```
**Expected**: `image.tag` matches the merge commit SHA, and the top log
entry is a `chore: bump demo-app image tag to <sha>` commit authored by
your bot identity.
```bash
# 3. Real Check on the merge commit
gh api repos/<org>/<app-repo>/commits/main/check-runs --jq '.check_runs[] | {name, conclusion}'
```
**Expected output** (real example):
```json
{"name":"Pipelines as Code CI / app-repo-push-main","conclusion":"success"}
```

**Confirm reproducibility:** trigger a second, unrelated commit to `main`
afterward and confirm it *also* triggers and succeeds automatically — one
green run can be luck (a cache warm from a prior manual test, a
coincidence in ordering); two in a row from independent triggers,
minutes apart, is real evidence the system is stable end-to-end, not
"worked once."

**If any independent check fails while the PipelineRun itself shows
green:** treat the PipelineRun's status as unreliable for that claim and
investigate the specific failing check — e.g., a `git push` inside the
Task can report success at the git level while pushing to the wrong
branch/remote if a param was misconfigured; only the independent,
fresh-clone check catches that class of bug.

---

## Gotchas quick-reference

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 0 | `gh` commands fail with auth errors | Stale/invalid OAuth token | `gh auth login` again, then `gh auth setup-git` |
| 1 | Real PR/push produces zero webhook activity, but "Recent Deliveries" shows 200s for *other* event types only | App's repo-access list silently dropped a repo when another was added later | Re-select **all** needed repos together under Settings → Applications → Configure |
| 2 | `failed to scope GitHub token as repo with pattern ... does not exist in namespace` | `github_app_token_scope_repos` target has no `Repository` CR of its own | Create a minimal `Repository` CR for the scoped repo too |
| 3 | `failed to scope GitHub token as repo scoped key secret-github-app-token-scoped is enabled` | Cluster-wide configmap flag blocks cross-repo scoping | `kubectl patch configmap pipelines-as-code -n pipelines-as-code --type=merge -p '{"data":{"secret-github-app-token-scoped":"false"}}'` |
| 4 | Custom Task's pod fails to create: `secretKeyRef.name: Invalid value: "{{ git_auth_secret }}"` | `{{ }}` substitution doesn't reach inside an inlined custom Task's `env` block | Read the token from the `basic-auth` workspace file instead of an env var |
| 5 | `microdnf install -y git yq` → `No package matches 'yq'` | `yq` isn't a UBI package; atomic transaction also skips `git` | Install `git` alone; download a **pinned-version** `yq` static binary directly |
| 6 | `buildah` push fails despite a Secret existing | Secret keyed `.dockerconfigjson` (from `create secret docker-registry`) but the Task reads `config.json` | Use `kubectl create secret generic ... --from-file=config.json=...` |
| 7 | `buildah` push fails: `permission_denied: token does not match expected scopes` | PAT missing `write:packages` | Reissue the PAT with `write:packages` |
| 8 | Task pod stuck `Pending` forever, `FailedMount` on a Secret that's unrelated to that task | `Coschedule: workspaces` requires all PipelineRun-level workspace secrets to exist before any task starts | Create the missing secret, or delete and retry once it exists |
| 9 | `{{ pull_request_number }}` ends up literal in a local dry run, `buildah` rejects the tag | Only populated by a real PR webhook event | Expected in local testing; substitute a placeholder in the *resolved copy only* to verify the rest of the chain |

---

## Security notes (learned the hard way)

- **Pin external binary downloads in any Task that carries write
  credentials**, not just Docker base images. `update-deployment-tag.yaml`
  downloads `yq` at every run and holds a git-push token to
  `deployment-repo` in the same step — a `.../releases/latest/download/...`
  URL means that Task's behavior (and its supply-chain trust boundary) can
  change on any upstream release, silently, with a live credential in
  scope. Pin an explicit version and bump it deliberately, the same as any
  other dependency.
- **Never verify a Secret's contents with a command that prints values**
  (`kubectl get secret ... -o jsonpath='{.data}'`). Use `kubectl describe
  secret` for key names only.
- **Never paste a real token/PAT/private key into a chat, issue, or log
  viewer.** If you must hand credentials to an assistant or automation,
  write them to a local file yourself and reference the file path — don't
  transmit the value through a channel that gets logged/retained.
- If a credential *does* end up somewhere it shouldn't (a transcript, a
  log, a screen share), **treat it as compromised regardless of whether
  it was actually misused** — rotate it. The cost of rotation is low; the
  cost of leaving a real credential live in an unintended place is not.
- Before running anything with a *working* credential that will cause a
  real external side effect (a registry push, a commit to a repo, sending
  a message), pause and confirm — a "dry run" stops being dry the moment
  the token actually works.
