#!/usr/bin/env bash
# Run the tekton_sa pipeline once and say whether it passed.
#
# Usage: tekton_sa/test.sh [revision]
#   revision  branch or commit SHA already pushed to GitHub (default: main)
set -euo pipefail
cd "$(dirname "$0")"

NS="${NAMESPACE:-cicd-demo}"
REVISION="${1:-main}"

# 1. Install the StepActions, then the Pipeline. The Pipeline's steps refer
#    to the StepActions by name; they are only looked up when a run starts.
kubectl apply -n "$NS" -f stepactions/ -f pipeline.yaml

# 2. Start a run for the requested revision.
RUN=$(sed "s|value: main|value: $REVISION|" pipelinerun.yaml | kubectl create -n "$NS" -f - -o name)
RUN=${RUN#*/}
echo "Started $RUN (revision: $REVISION)"

# 3. Follow the logs until the run finishes.
tkn pipelinerun logs "$RUN" -n "$NS" -f || true

# 4. Report the result.
STATUS=$(kubectl get pipelinerun "$RUN" -n "$NS" -o jsonpath='{.status.conditions[0].status}')
if [ "$STATUS" = "True" ]; then
  echo "PASS: $RUN"
else
  echo "FAIL: $RUN"
  exit 1
fi
