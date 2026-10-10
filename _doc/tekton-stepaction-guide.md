# Tekton StepAction: Concepts and Guide

*As of 2026-10-10 · Based on the official Tekton Pipelines docs and release notes · Verify field details against the docs for your installed Pipelines version.*

> **Refined question:** What is Tekton StepAction, why was it introduced, and how do I write, reference, version, secure and troubleshoot it?

---

## Table of contents

1. [What is a StepAction](#1-what-is-a-stepaction)
2. [Why it exists](#2-why-it-exists)
3. [Maturity and history](#3-maturity-and-history)
4. [Anatomy of a StepAction](#4-anatomy-of-a-stepaction)
5. [Referencing a StepAction](#5-referencing-a-stepaction)
6. [Params](#6-params)
7. [Results](#7-results)
8. [Env, secrets, volumes and workspaces](#8-env-secrets-volumes-and-workspaces)
9. [Remote resolution](#9-remote-resolution)
10. [Using StepActions in a Pipeline](#10-using-stepactions-in-a-pipeline)
11. [Converting inline Steps to StepActions](#11-converting-inline-steps-to-stepactions)
12. [Check that it is enabled](#12-check-that-it-is-enabled)
13. [Best practices](#13-best-practices)
14. [Troubleshooting](#14-troubleshooting)
15. [Cheat sheet](#15-cheat-sheet)
16. [Sources](#16-sources)

---

## 1. What is a StepAction

A **StepAction** is a reusable, scriptable unit of work performed by a **Step**.

Key ideas from the official docs:

- A Step itself is not reusable. The *work* it does is.
- Steps are inlined in a Task and either do work directly or run a StepAction.
- A StepAction **cannot run stand-alone**. It has no TaskRun or PipelineRun of its own. A Step must reference it.
- A Step is not "composed of" StepActions. A Step is an actionable component that can *refer to* one.

```text
PipelineRun ─▶ Pipeline ─▶ Task ─▶ Step ─ref▶ StepAction
                                     └─ or inline image/script
```

| Concept | Reusable? | Runs alone? | Granularity |
| --- | --- | --- | --- |
| Pipeline | Yes | Via PipelineRun | Many Tasks |
| Task | Yes | Via TaskRun | Many Steps (one Pod) |
| Step | No (inline in Task) | No | One container |
| **StepAction** | **Yes** | **No** | **One container's work** |

## 2. Why it exists

Before StepActions, sharing a single Step meant copying YAML between Tasks, or wrapping it in a whole new Task (a separate Pod, with workspace and result plumbing). StepActions give you:

- **Step-level reuse** inside a single Pod, with no extra Pod per reusable action.
- **Step-level results** (`StepResults`) so one Step can hand values to the next Step in the same Task.
- **Central maintenance**: fix an action once, every Task that references it benefits.
- **Remote sharing** via resolvers (git, bundles, hub, cluster, http).

## 3. Maturity and history

| Release | What changed (from release notes) |
| --- | --- |
| v0.53 (LTS) | `StepAction` CRD introduced, gated by feature flag `enable-step-actions` (default false) |
| v0.54 | Referencing syntax (`ref`) in Steps, `params` and `results` in StepAction, remote resolution, VolumeMounts, SecurityContext, step results |
| Later | Promoted to beta, then labelled stable in the current docs |

The current docs page says **"StepActions is a stable feature"**, while some versioned docs (for example the pre-stable `pipelines-main` vault and v0.56 LTS pages) call it beta or alpha. The `StepAction` resource is most commonly written as `tekton.dev/v1beta1`, and a `tekton.dev/v1` API reference also exists. **Check which `apiVersion` your cluster serves:**

```bash
kubectl api-resources | grep -i stepaction
kubectl get crd stepactions.tekton.dev -o jsonpath='{.spec.versions[*].name}'
```

## 4. Anatomy of a StepAction

Required fields: `apiVersion`, `kind`, `metadata`, `spec`, and `spec.image`. The image must follow the Tekton [container contract](https://tekton.dev/docs/pipelines/container-contract/).

Optional fields: `command` (cannot be combined with `script`), `args`, `script` (cannot be combined with `command`), `env`, `params`, `results`, `workingDir`, `securityContext`, `volumeMounts`, `description`.

```yaml
apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata:
  name: print-date
spec:
  description: Prints the current date and records it as a step result.
  results:
    - name: unix-ts
      description: Current time as a unix timestamp.
  image: bash:latest
  script: |
    #!/usr/bin/env bash
    date +%s | tee $(step.results.unix-ts.path)
```

## 5. Referencing a StepAction

A Step uses `ref` instead of `image`/`script`:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: demo
spec:
  steps:
    - name: stamp
      ref:
        name: print-date
```

### Which Step fields are allowed with `ref`?

| Not allowed with `ref` (validation error) | Allowed with `ref` |
| --- | --- |
| `image`, `command`, `args`, `script` | `ref`, `params` |
| `env`, `volumeMounts` | `computeResources`, `timeout`, `onError` |
| | `workspaces` (isolated workspaces), `volumeDevices` |
| | `imagePullPolicy`, `securityContext`, `envFrom` |
| | `stdoutConfig`, `stderrConfig` |

Example error when mixing `image` with `ref`:

```text
validation failed: image cannot be used with Ref: spec.taskSpec.steps[0].image
```

Allowed extras in practice:

```yaml
steps:
  - name: action-runner
    ref:
      name: step-action
    params:
      - name: step-action-param
        value: hello
    computeResources:
      requests: {memory: 1Gi, cpu: 500m}
    timeout: 1h
    onError: continue
```

Note: `securityContext` declared in a StepAction **overrides** the one from the TaskRun.

## 6. Params

Declare params like in a Task (name, type `string`/`array`/`object`, optional `default`). The referencing Step passes values via its `params`.

```yaml
apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata:
  name: stepaction-using-params
spec:
  params:
    - name: gitrepo
      type: object
      properties:
        url: {type: string}
        commit: {type: string}
    - name: flags
      type: array
    - name: outputPath
      type: string
      default: "/workspace"
  image: some-git-image
  args: [
    "-url=$(params.gitrepo.url)",
    "-revision=$(params.gitrepo.commit)",
    "-output=$(params.outputPath)",
    "$(params.flags[*])",
  ]
```

### Important: do not put `$(params.x)` directly in `script`

The docs state that `params` **cannot be used directly in a `script` in StepActions**, because direct substitution makes the workload prone to shell injection. Route the value through `env` and read the environment variable in the script:

```yaml
apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata:
  name: git-clone-lite
spec:
  description: Shallow-clones a repo and records the commit SHA.
  params:
    - name: url
      type: string
      description: Git repository URL.
    - name: dest
      type: string
      default: /workspace/src
  results:
    - name: commit
  image: alpine/git
  env:
    - name: REPO_URL
      value: $(params.url)
    - name: DEST
      value: $(params.dest)
  script: |
    #!/bin/sh
    set -e
    git clone --depth 1 "$REPO_URL" "$DEST"
    git -C "$DEST" rev-parse HEAD | tr -d '\n' > $(step.results.commit.path)
```

(Result paths such as `$(step.results.commit.path)` are substitutions Tekton provides and are fine in `script`.)

### Passing Task params to the Step

```yaml
spec:
  params:
    - name: repo
  steps:
    - name: clone
      ref:
        name: git-clone-lite
      params:
        - name: url
          value: $(params.repo)    # Task param -> StepAction param
```

A Step that references a StepAction passes params in its own `params`. An *inline* Step must not declare `params` (it gets them from the TaskRun), or validation fails.

### Substitution order

1. TaskRun parameter values used inside Step params
2. Step-provided parameter values
3. Defaults that reference other params
4. Simple defaults
5. Step result references (resolved last)

## 7. Results

A StepAction declares `results` and writes them to **`$(step.results.<name>.path)`**.

```yaml
results:
  - name: current-date-unix-timestamp
    description: The current date in unix timestamp format
script: |
  #!/usr/bin/env bash
  date +%s | tee $(step.results.current-date-unix-timestamp.path)
```

Why `step.results` and not `results`? A Task can use the same StepAction twice, or two StepActions can emit the same result name. Step-level storage lets the Task disambiguate.

### Reading results

| Where | Syntax |
| --- | --- |
| Later Step or StepAction | `$(steps.<step-name>.results.<result-name>)` |
| Task result (export to TaskRun) | `value: $(steps.<step-name>.results.<result-name>)` |
| Later pipeline task | `$(tasks.<task-name>.results.<result-name>)` |

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: task-fetching-results
spec:
  results:
    - name: commit
      value: $(steps.clone.results.commit)
  steps:
    - name: clone
      ref:
        name: git-clone-lite
      params:
        - name: url
          value: https://github.com/org/repo
```

Rules to remember:

- Step results are **not** automatically TaskRun results. The Task must copy each one explicitly via `value:`.
- Step results can only be referenced in a Step's or StepAction's `env`, `command` and `args`. Referencing them in any other field errors out. Whole-array results (`[*]`) cannot be referenced in `script` or `env`.
- String results are stable. Array and object results require `enable-api-fields` of `alpha` or `beta`.

Since results are limited to `env`/`command`/`args`, consume them like this:

```yaml
- name: show
  ref:
    name: print-value
  params:
    - name: value
      value: $(steps.clone.results.commit)
```

## 8. Env, secrets, volumes and workspaces

Because a Step with `ref` cannot set `env` or `volumeMounts`, the StepAction itself owns those, and parameterizes them.

### Env from params

```yaml
spec:
  params:
    - name: home
      default: /tekton/home
  env:
    - name: HOME
      value: $(params.home)
```

### Secrets

- Use `envFrom` on the referencing Step (allowed with `ref`), or
- Declare `env` with `valueFrom.secretKeyRef` in the StepAction and make the secret name a param, or
- Mount the Secret as a volume (see below).

### VolumeMounts

The `name` of a StepAction `volumeMount` **must be exactly one string param reference**. `$(params.registryConfig)` is valid. `$(params.registryConfig)-foo` and `"hardcoded"` are invalid. This lets the Task author choose which volume to bind.

```yaml
apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata:
  name: push-image
spec:
  params:
    - name: registryConfig
  volumeMounts:
    - name: $(params.registryConfig)
      mountPath: /registry-config
  image: example/pusher
  script: |
    ls /registry-config
```

```yaml
# Task side
spec:
  volumes:
    - name: docker-config
      secret:
        secretName: regcred
  steps:
    - name: push
      ref:
        name: push-image
      params:
        - name: registryConfig
          value: docker-config      # the volume's name
```

### WorkingDir

Parameterize it so the Task controls the location:

```yaml
spec:
  params:
    - name: source
  workingDir: $(params.source)
```

### Workspaces

A StepAction does not declare workspaces. The Step may use isolated `workspaces`, or you pass `$(workspaces.<name>.path)` as a param value to a path param.

## 9. Remote resolution

A `ref` can point to a remote StepAction using a resolver (git, bundles, hub, cluster, http). Resolvers must be enabled by your cluster operator.

```yaml
steps:
  - name: action-runner
    ref:
      resolver: git
      params:
        - name: url
          value: https://github.com/org/catalog.git
        - name: revision
          value: <commit-sha-or-tag>
        - name: pathInRepo
          value: stepactions/git-clone-lite.yaml
```

Pin `revision` to a tag or commit for reproducibility. A default resolver type can be set with `default-resolver-type` in the `config-defaults` ConfigMap (alpha).

## 10. Using StepActions in a Pipeline

A Pipeline cannot reference a StepAction directly. It references Tasks, and Tasks contain Steps. Use an embedded `taskSpec` to keep everything in one file:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ci
spec:
  params:
    - name: repo
  tasks:
    - name: build
      params:
        - name: repo
          value: $(params.repo)
      taskSpec:
        params:
          - name: repo
        results:
          - name: commit
            value: $(steps.clone.results.commit)
        steps:
          - name: clone
            ref:
              name: git-clone-lite
            params:
              - name: url
                value: $(params.repo)
    - name: report
      runAfter: [build]
      params:
        - name: commit
          value: $(tasks.build.results.commit)
      taskSpec:
        params:
          - name: commit
        steps:
          - name: show
            image: alpine
            env:
              - name: COMMIT
                value: $(params.commit)
            script: echo "built $COMMIT"
```

`taskSpec` does not create a Task object. It embeds the Task spec, and Tekton creates a TaskRun with the copied spec at run time.

## 11. Converting inline Steps to StepActions

There is no automatic converter. Do it by hand:

1. Copy the Step's `image`, `script` (or `command`/`args`), `workingDir`, `securityContext` into a new StepAction.
2. Declare each input as a StepAction `param`; replace Task `$(params.x)` use with StepAction params.
3. **Move param use out of `script`**: pass each through `env` and read `$VAR` in the script.
4. Replace `$(results.x.path)` with `$(step.results.x.path)` and declare `results`.
5. Move `env` and `volumeMounts` into the StepAction (parameterized).
6. Replace the Step body with `ref` + `params`; keep `computeResources`, `timeout`, `onError` etc. on the Step.
7. Export needed step results as Task `results` with `value:`.
8. Apply with `kubectl apply --dry-run=server`, then run a TaskRun before deleting the old inline Step.

**Before**

```yaml
steps:
  - name: test
    image: golang:1.23
    workingDir: /workspace/src
    script: |
      go test ./...
```

**After**

```yaml
# StepAction
apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata:
  name: go-test
spec:
  description: Runs go test for all packages under a source directory.
  params:
    - name: source
      default: /workspace/src
  image: golang:1.23
  workingDir: $(params.source)
  script: |
    #!/bin/sh
    set -e
    go test ./...
---
# Task step
steps:
  - name: test
    ref:
      name: go-test
```

(`workingDir` may use params. Only `script` is restricted.)

## 12. Check that it is enabled

```bash
# 1. CRD exists?
kubectl get crd stepactions.tekton.dev

# 2. Pipelines version
kubectl get deploy tekton-pipelines-controller -n tekton-pipelines \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}'

# 3. Feature flag (older versions gate StepActions)
kubectl get cm feature-flags -n tekton-pipelines -o yaml | grep -i step-actions

# 4. Functional test
kubectl apply --dry-run=server -f stepaction.yaml
```

In versions that gate the feature, `enable-step-actions` defaults to `false` and must be `"true"` to specify a StepAction in a Step. With the Tekton Operator, set it in `TektonConfig` or `TektonPipeline` (`spec.pipeline` / `spec`) rather than editing the ConfigMap, or the operator reverts it. The current docs page no longer mentions the flag, so on recent releases it may be removed. Check your version's release notes.

## 13. Best practices

- **One purpose per StepAction**, with documented params and results (`description` on everything).
- **Pass params through `env`**, never directly in `script`.
- **Pin images by digest** and remote refs by commit or tag.
- **Keep volume coupling parameterized** (`$(params.volName)`), not hardcoded.
- **Use `onError`, `timeout`, `computeResources` on the Step**, not baked into the StepAction.
- **Export results explicitly** in the Task (`value: $(steps.x.results.y)`).
- **Version through git or bundles** and avoid mutating a shared in-cluster StepAction used by many pipelines.
- For supply-chain controls, combine remote refs with Tekton **Trusted Resources** verification.

## 14. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `image cannot be used with Ref` | Step has `image`, `command`, `args`, `script`, `env` or `volumeMounts` next to `ref` | Move those into the StepAction |
| Validation error about `params` in `script` | `$(params.x)` used directly in StepAction `script` | Pass via `env`, read `$VAR` |
| Webhook rejects `ref` / "step actions not enabled" | Older Pipelines with `enable-step-actions: false` | Enable the flag (or `TektonConfig`) or upgrade |
| `stepactions.tekton.dev` not found | Pipelines too old (before v0.53) | Upgrade Pipelines |
| StepAction not found | Wrong namespace or name; resolver not enabled | `kubectl get stepaction -n <ns>`; check resolver flags |
| Step result empty in later Step | Written to `$(results...)` instead of `$(step.results...)` | Use `$(step.results.<name>.path)` |
| TaskRun has no result | Step result not copied to Task `results` | Add `value: $(steps.<step>.results.<name>)` |
| Step result reference rejected | Used outside `env`/`command`/`args` | Pass it as a param into `env`/`args` |
| Volume mount fails | `volumeMount.name` not a single param reference, or the Task lacks that volume | Use `$(params.x)` alone; declare the volume in the Task |
| Different `securityContext` than expected | StepAction overrides TaskRun | Align or remove it in one place |

Debug commands:

```bash
kubectl get stepaction -n <ns>
tkn taskrun describe <name>
kubectl get taskrun <name> -o jsonpath='{.status.taskSpec}'   # resolved spec
kubectl get pod <taskrun-pod> -o yaml                          # final env/mounts
```

## 15. Cheat sheet

```yaml
# Define
apiVersion: tekton.dev/v1beta1
kind: StepAction
metadata: {name: my-action}
spec:
  description: ...
  params: [{name: x, default: "y"}]
  results: [{name: out}]
  env: [{name: X, value: $(params.x)}]     # params -> env -> script
  image: alpine
  script: |
    echo "$X" > $(step.results.out.path)

# Use
steps:
  - name: s1
    ref: {name: my-action}                  # or resolver: git ...
    params: [{name: x, value: hello}]
    timeout: 10m
    onError: continue
# Export
results:
  - name: out
    value: $(steps.s1.results.out)
```

## 16. Sources

- [Tekton Pipelines: StepActions](https://tekton.dev/docs/pipelines/stepactions/)
- [Tekton Pipelines: StepActions (versioned vault, v0.56 LTS)](https://tekton.dev/vault/pipelines-v0.56.x-lts/stepactions)
- [Tekton Operator: TektonPipeline (feature flags)](https://tekton.dev/vault/operator-v0.73.x-lts/tektonpipeline/)
- [Release v0.53.0 notes](https://github.com/tektoncd/pipeline/discussions/7292)
- [Release v0.54.0 notes](https://www.github.com/tektoncd/pipeline/discussions/7426)
- [TEP-0142: Enable Step Reusability](https://github.com/tektoncd/community/blob/main/teps/0142-enable-step-reusability.md)
- [Tekton Pipelines: Remote Resolution](https://tekton.dev/docs/pipelines/resolution/)

*Exact promotion versions (alpha → beta → stable) and whether the feature flag still exists in your release are not stated on the pages above. Confirm against the release notes for the version you run.*
