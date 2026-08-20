# Phase 2 — GitHub App & Cluster Secret

Creates the GitHub App PAC authenticates as, and the cluster Secret PAC
reads to use it. Corresponds to Phase 2 of
`topic/20260820-1_init_tekton_cicd_example/20.plan.md`. Depends on Phase 1
(`../README.md`) being done first — the App's Webhook URL is either your
Ingress host or the gosmee forwarder endpoint.

This phase is **manual/interactive by nature**: creating a GitHub App and
downloading its private key is a browser-based, credential-generating GitHub
action that only an org admin can do — it is not something to script or
automate end-to-end. What's provided here is a runbook plus one script for
the one part that *is* mechanical (loading the resulting credentials into
the cluster as a Secret).

## Prerequisites
- GitHub org/user admin rights (to create and install the App).
- `kubectl` pointed at the cluster from Phase 1.
- Phase 1 complete: PAC deployments healthy, webhook delivery path decided
  (real Ingress host, or gosmee — see `../README.md`).

## Option A — automated via `tkn pac bootstrap` (recommended if available)

Requires the `tkn-pac` CLI plugin (not installed in this environment —
install it separately, e.g. via the `tektoncd/pipelines-as-code` releases
page or your package manager).

```bash
tkn pac bootstrap
# or, to only do the App + secret step (PAC already installed):
tkn pac bootstrap github-app
```

This walks you through App creation in the browser (via GitHub's App
Manifest flow), auto-detects your Ingress/Route or asks for the URL
(`--route-url` to override), and writes the `pipelines-as-code-secret`
directly — skip the manual steps below if you use this path.

## Option B — manual

1. Go to <https://github.com/settings/apps> → **New GitHub App** (or your
   org's equivalent settings page for an org-owned App).
2. Fill in:
   - **GitHub Application name**: e.g. `pac-java-cicd-<something-unique>`
     (must be globally unique across all of GitHub).
   - **Homepage URL**: any placeholder, or your cluster console URL.
   - **Webhook URL**: the Ingress host from Phase 1, or (if using gosmee)
     the forwarder URL gosmee prints when started.
   - **Webhook secret**: generate one, e.g. `head -c 30 /dev/random | base64`.
3. **Repository permissions**: Checks (Read & Write), Contents (Read &
   Write), Issues (Read & Write), Metadata (Read-only), Pull requests
   (Read & Write).
4. **Organization permissions**: Members (Read-only).
5. **Subscribe to events**: Check run, Check suite, Commit comment, Issue
   comment, Pull request, Push.
6. Create the App. Note the **App ID** shown on its settings page.
7. Under **Private keys**, click **Generate a private key** — downloads a
   `.pem` file. Store it somewhere outside the repo (or in this repo's
   working tree only — `.gitignore` at the repo root already excludes
   `*.pem`, but treat it as sensitive regardless).
8. Load the credentials into the cluster:
   ```bash
   APP_ID=<the App ID from step 6> \
   PRIVATE_KEY_PATH=/path/to/downloaded-key.pem \
   WEBHOOK_SECRET='<the secret you generated in step 2>' \
   ./create-secret.sh
   ```
9. Install the App on this repo: from the App's **Install App** page,
   select this repo (`ex-cicd-tektonpac`). **Do not** install it on
   `deployment-repo` yet — that repo doesn't exist until Phase 3; come back
   and add it once Phase 3 is done.

## Exit criteria
- ✅ GitHub App exists with the permissions/events above.
- ✅ `kubectl -n pipelines-as-code get secret pipelines-as-code-secret` shows
  the secret with keys `github-private-key`, `github-application-id`,
  `webhook.secret`.
- ✅ App is installed on this repo (`ex-cicd-tektonpac`).

## Status
**Complete.** Executed via Option A (`tkn-pac bootstrap github-app`) against
the live cluster: GitHub App **`pac-ex-cicd-tektonpac`** created under the
`catsrang` account (<https://github.com/apps/pac-ex-cicd-tektonpac>);
`pipelines-as-code-secret` created directly by the bootstrap tool in the
`pipelines-as-code` namespace; App installed on `catsrang/ex-cicd-tektonpac`
(confirmed 2026-08-20). `create-secret.sh` was not needed since bootstrap
wrote the secret itself, but remains available for manual/Option B use or
re-running with rotated credentials.

SSL verification has been disabled on the App's webhook settings (self-signed
cert on `bless2k.duckdns.org` is no longer a blocker for webhook delivery).

Still open (non-blocking for this phase, needed before later phases):
- Private key rotation recommended but not done — an earlier verification
  command printed the key's base64 value into a conversation transcript.
  See `30.impl.md` Phase 2 for details.
