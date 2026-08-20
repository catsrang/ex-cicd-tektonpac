# Implementation Guide: Tekton Pipelines-as-Code CI/CD Example

Step-by-step guide to reproduce this repo's setup from scratch, with the
exact verification command for every step. Written after actually doing
it once (see `topic/20260820-1_init_tekton_cicd_example/30.impl.md` for
the chronological log with every wrong turn); this guide gives you the
*correct* path directly, with the real gotchas called out where they'd
otherwise bite you.

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

## Step 1 — Install PAC on the cluster

```bash
kubectl apply -f https://raw.githubusercontent.com/tektoncd/pipelines-as-code/stable/release.k8s.yaml
kubectl -n pipelines-as-code wait --for=condition=Available --timeout=180s deployment --all
```

**Verify:**
```bash
kubectl get deployment -n pipelines-as-code
# controller, webhook, watcher all 1/1

kubectl get pods -n pipelines-as-code
# all Running, 0 restarts
```

## Step 2 — Expose the controller to GitHub

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
# 200
```
> If your cluster has no cert-manager, this'll be a self-signed cert —
> `curl` needs `-k`/`--insecure`. **You'll need to disable "SSL
> verification" on the GitHub App's webhook settings too (Step 3)**,
> or every real webhook delivery will fail TLS verification.

---

## Step 3 — Create the GitHub App

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

**Verify the secret:**
```bash
kubectl -n pipelines-as-code get secret pipelines-as-code-secret
# Should show 3 keys: github-application-id, github-private-key, webhook.secret
```
> ⚠️ **Don't verify the secret's *values*** with something like
> `kubectl get secret ... -o jsonpath='{.data}'` — that prints the
> base64-encoded private key into whatever log/terminal you're in. Check
> **key names only**: `kubectl describe secret pipelines-as-code-secret -n pipelines-as-code`
> shows key names and byte sizes without printing values.

**Then, manually (no API path exists for this):**
1. Disable "SSL verification" on the App's webhook settings if using a
   self-signed cert (Step 2's caveat).
2. Install the App — but see the critical gotcha below before you do.

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

**Verify** (this is the check that would have caught the bug immediately):
1. Go to `https://github.com/settings/installations` → **Configure** next
   to your App.
2. Under "Repository access", confirm **both** repos are listed (or "All
   repositories" is selected).
3. The definitive functional test: push a trivial commit to `app-repo`
   and watch for controller activity —
   ```bash
   kubectl logs -n pipelines-as-code -l app.kubernetes.io/name=pipelines-as-code-controller -f --since=1s
   ```
   then push. You should see `event-type":"push"` (or `pull_request`)
   within a few seconds. **Silence here, with a `200` on the App's
   "Recent Deliveries" page, almost always means this exact bug** — check
   the repo-access list, not the webhook config.

---

## Step 4 — Create `deployment-repo`

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

Install the App here too (see Gotcha #1 — do this in the same sitting as
Step 3's install, not as an afterthought).

**Verify:**
```bash
git ls-remote git@github.com:<org>/<deployment-repo>.git
# shows a ref for main now, not empty
```

---

## Step 5 — Register `Repository` CRs — **for both repos**

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
# Resolves cleanly, shows the right URL/namespace, "No runs has started" (expected pre-Step-9)

kubectl get repository -n cicd-demo
# Both CRs listed
```

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
controller live-reloads it, no restart needed.

**Verify both fixes together:** push any commit and check the controller
logs (same command as Gotcha #1's verification) — you should see:
```
"msg":"Github token scope extended to [<org>/<deployment-repo> <org>/<app-repo>]"
```
instead of a `failed to scope` error.

---

## Step 6 — Scaffold the app

Standard Maven/Spring Boot layout — nothing PAC-specific here. Minimal:
`pom.xml`, `src/main/java/.../Application.java`,
`src/test/java/.../ApplicationTests.java`, `Dockerfile`.

**Verify:**
```bash
mvn test
# green, independent of any pipeline

docker build -t demo-app .   # or podman build
# succeeds
```

---

## Step 7 — Write `.tekton/` pipeline definitions

Before writing `IMAGE` params, **check which catalog your cluster's PAC
actually resolves Tasks from** — don't assume it's `hub.tekton.dev`:
```bash
kubectl get configmap pipelines-as-code -n pipelines-as-code -o jsonpath='{.data.hub-url}'
```
Newer PAC versions default to `https://artifacthub.io`. Fetch the real
Task definitions from there (or from the `tektoncd/catalog` repo the
Artifact Hub package points to) and check their actual `params`/
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
kubectl apply --dry-run=client -f .tekton/tasks/*.yaml
# all accepted against the real PipelineRun/Task CRD schemas
```

**Verify resolution** (needs `tkn-pac` and repo push access, see Step 9):
```bash
tkn-pac resolve -f .tekton/pr.yaml -o /tmp/pr-resolved.yaml
grep -c "taskSpec:" /tmp/pr-resolved.yaml   # should be > 0, i.e. real inlined Tasks, not stubs

tkn-pac resolve --no-secret -f .tekton/push.yaml -o /tmp/push-resolved.yaml
# --no-secret avoids an interactive prompt when {{ git_auth_secret }} is detected
```

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
gets rejected by Kubernetes' name validation (`PodCreationFailed`).

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

**Verify:** `kubectl describe secret <pac-gitauth-*> -n cicd-demo` (name
varies per run) shows those three keys without printing values.

## ⚠️ Gotcha #5 — `yq` isn't a `microdnf` package on UBI minimal images

```bash
microdnf install -y git yq   # fails: "error: No package matches 'yq'"
```
Because `microdnf` resolves the whole install atomically, this also means
`git` silently never got installed either. Fix: install `git` alone,
download the static `yq` binary directly:
```bash
microdnf install -y git
curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
```
(Check your node's architecture first — `kubectl get nodes -o
custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture` —
and swap `amd64` for `arm64` if needed.)

Related: **don't** also `microdnf install curl` on top of this — UBI
minimal ships `curl-minimal` by default, and installing the full `curl`
package conflicts with it (`depsolve` error). `curl-minimal` already
provides what you need.

---

## Step 8 — Create the registry credentials Secret

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

The PAT needs the **`write:packages`** scope specifically (a token with
only `repo`/`workflow` will create the Secret fine but fail at push time
with `permission_denied: The token provided does not match expected
scopes`).

**Verify:**
```bash
kubectl get secret ghcr-credentials -n cicd-demo -o jsonpath='{.data}' | \
  python3 -c "import json,sys; print(list(json.load(sys.stdin).keys()))"
# ['config.json']
```
Check the token's actual scopes before trusting it, without ever
printing the token itself:
```bash
curl -s -o /dev/null -D - -H "Authorization: token $TOKEN" https://api.github.com/user | grep -i x-oauth-scopes
```

---

## Step 9 — Local dry run

Commit and push everything to `main` first — `git-clone` needs real
content to fetch, and `pipelinerun_provenance: default_branch` means PAC
resolves `.tekton/` from whatever's actually on `main`.

```bash
tkn-pac resolve -f .tekton/pr.yaml -o /tmp/pr-resolved.yaml
kubectl create -f /tmp/pr-resolved.yaml -n cicd-demo
kubectl get pipelinerun -n cicd-demo -w
```

**Expected**: `pr.yaml` should run to completion — *except* the
`buildah` step's `IMAGE` param, if it uses `{{ pull_request_number }}`,
will fail with `invalid reference format`, because that variable is only
populated by a real PR webhook event; `tkn-pac resolve` has no PR context
to fill it with locally. This is expected and not a bug — it'll resolve
correctly once a real PR triggers it (Step 10). You can isolate/confirm
the rest of the chain by substituting a placeholder value into the
*local resolved copy only* (never the committed `.tekton/pr.yaml`) and
re-applying.

For `push.yaml`, the plan's own stated acceptable outcome is: "resolved
without error, or fails for expected/understood reasons (e.g. missing
registry creds)" — don't force a full local run past that point unless
you also want to exercise the real credential path (see next section).

**Verify a `push.yaml` PipelineRun's terminal state, whichever it is:**
```bash
kubectl get pipelinerun -n cicd-demo <name>
kubectl get taskrun -n cicd-demo -l tekton.dev/pipelineRun=<name>
kubectl logs -n cicd-demo -l tekton.dev/pipelineTask=<failing-task>,tekton.dev/pipelineRun=<name> --all-containers=true
```

> ⚠️ If a task-run pod gets stuck `Pending` forever instead of cleanly
> `Failed`, check `kubectl describe pod <pod>` for `FailedMount` on a
> Secret volume — some Tekton versions with `Coschedule: workspaces`
> enabled require *all* PipelineRun-level workspace secrets to exist
> before *any* task's pod can start, not just the task that binds them.
> `kubectl delete pipelinerun <name>` to clean up a stuck run.

---

## Step 10 — Real end-to-end validation

```bash
git checkout -b test-branch
# make a small real change
git push -u origin test-branch
gh pr create --base main --head test-branch --title "..." --body "..."
```

**Verify the PR pipeline fired for real:**
```bash
gh pr checks <PR-number>
# "Pipelines as Code CI / <pr-pipeline-name>  pass"
```

If nothing shows up after ~30s, don't assume it's still "processing" —
go straight to Gotcha #1's verification steps. Silence is the symptom of
that bug specifically, not of slowness.

**Exercise a GitOps command:**
```bash
gh pr comment <PR-number> --body "/retest"
```
Expected on an already-passing PR: the controller logs *"All PipelineRuns
for this commit have already succeeded"* and correctly declines to
duplicate the run — that's success, not a failed trigger.

**Merge and verify the push pipeline:**
```bash
gh pr merge <PR-number> --merge --delete-branch
```

**Verify independently — don't just trust the green PipelineRun status:**
```bash
# 1. Real image in the registry
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/users/<owner>/packages/container/<image>/versions" | \
  python3 -c "import json,sys; [print(v['metadata']['container']['tags']) for v in json.load(sys.stdin)[:3]]"

# 2. Real commit in deployment-repo — clone fresh, don't reuse the Task's own working copy
git clone git@github.com:<org>/<deployment-repo>.git /tmp/verify
cat /tmp/verify/charts/demo-app/values.yaml
git -C /tmp/verify log --oneline -3
rm -rf /tmp/verify

# 3. Real Check on the merge commit
gh api repos/<org>/<app-repo>/commits/main/check-runs --jq '.check_runs[] | {name, conclusion}'
```

If you can, trigger a second, unrelated commit to `main` afterward and
confirm it *also* triggers and succeeds automatically — one green run can
be luck; two in a row from independent triggers is real evidence the
system is stable, not just "worked once."

---

## Gotchas quick-reference

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 0 | `gh` commands fail with auth errors | Stale/invalid OAuth token | `gh auth login` again, then `gh auth setup-git` |
| 1 | Real PR/push produces zero webhook activity, but "Recent Deliveries" shows 200s for *other* event types only | App's repo-access list silently dropped a repo when another was added later | Re-select **all** needed repos together under Settings → Applications → Configure |
| 2 | `failed to scope GitHub token as repo with pattern ... does not exist in namespace` | `github_app_token_scope_repos` target has no `Repository` CR of its own | Create a minimal `Repository` CR for the scoped repo too |
| 3 | `failed to scope GitHub token as repo scoped key secret-github-app-token-scoped is enabled` | Cluster-wide configmap flag blocks cross-repo scoping | `kubectl patch configmap pipelines-as-code -n pipelines-as-code --type=merge -p '{"data":{"secret-github-app-token-scoped":"false"}}'` |
| 4 | Custom Task's pod fails to create: `secretKeyRef.name: Invalid value: "{{ git_auth_secret }}"` | `{{ }}` substitution doesn't reach inside an inlined custom Task's `env` block | Read the token from the `basic-auth` workspace file instead of an env var |
| 5 | `microdnf install -y git yq` → `No package matches 'yq'` | `yq` isn't a UBI package; atomic transaction also skips `git` | Install `git` alone; download the `yq` static binary directly |
| 6 | `buildah` push fails despite a Secret existing | Secret keyed `.dockerconfigjson` (from `create secret docker-registry`) but the Task reads `config.json` | Use `kubectl create secret generic ... --from-file=config.json=...` |
| 7 | `buildah` push fails: `permission_denied: token does not match expected scopes` | PAT missing `write:packages` | Reissue the PAT with `write:packages` |
| 8 | Task pod stuck `Pending` forever, `FailedMount` on a Secret that's unrelated to that task | `Coschedule: workspaces` requires all PipelineRun-level workspace secrets to exist before any task starts | Create the missing secret, or delete and retry once it exists |
| 9 | `{{ pull_request_number }}` ends up literal in a local dry run, `buildah` rejects the tag | Only populated by a real PR webhook event | Expected in local testing; substitute a placeholder in the *resolved copy only* to verify the rest of the chain |

---

## Security notes (learned the hard way)

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
