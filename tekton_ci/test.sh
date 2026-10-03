#!/usr/bin/env bash
# Apply the tekton_ci Task + Pipeline, start a PipelineRun, wait for it and
# check that the build really ran on a memory workspace and handed off via
# one shared PVC.
#
# Usage:   tekton_ci/test.sh [revision]
#   revision   branch or commit SHA that is already pushed to REPO_URL
#              (default: main). It must contain the runtime-only Dockerfile.
# Env:     NAMESPACE (cicd-demo)  REPO_URL (value in pipelinerun.yaml)
#          TIMEOUT seconds (600)  CLEANUP=1 deletes the run when it succeeds
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-cicd-demo}"
REVISION="${1:-${REVISION:-main}}"
REPO_URL="${REPO_URL:-}"
TIMEOUT="${TIMEOUT:-600}"
CLEANUP="${CLEANUP:-0}"

k() { kubectl -n "${NAMESPACE}" "$@"; }
fails=0
check() { # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1 (expected '$3', got '$2')"
    fails=$((fails + 1))
  fi
}

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

echo "==> Applying Task and Pipeline to namespace '${NAMESPACE}'"
k apply -f "${DIR}/task.yaml" -f "${DIR}/pipeline.yaml"

echo "==> Starting PipelineRun (revision: ${REVISION})"
RUN="$(awk -v rev="${REVISION}" -v url="${REPO_URL}" '
  /- name: revision/           { print; pending = "rev"; next }
  /- name: repo_url/           { print; pending = "url"; next }
  pending == "rev" && /value:/ { sub(/value:.*/, "value: \"" rev "\""); pending = "" }
  pending == "url" && /value:/ { if (url != "") sub(/value:.*/, "value: \"" url "\""); pending = "" }
  { print }
' "${DIR}/pipelinerun.yaml" | k create -f - -o name)"
RUN="${RUN#*/}"
echo "    ${RUN}"

echo "==> Waiting for completion (timeout ${TIMEOUT}s)"
status="Unknown"
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  status="$(k get pipelinerun "${RUN}" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" || "${status}" == "False" ]] && break
  sleep 5
done

echo
k get taskrun -l "tekton.dev/pipelineRun=${RUN}"
echo

BUILD_POD="$(k get pod -l "tekton.dev/pipelineRun=${RUN},tekton.dev/pipelineTask=clone-build" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
IMAGE_POD="$(k get pod -l "tekton.dev/pipelineRun=${RUN},tekton.dev/pipelineTask=build-image" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

echo "==> Checks"
check "PipelineRun succeeded" "${status}" "True"
if [[ -n "${BUILD_POD}" ]]; then
  check "build workspace is a memory emptyDir" \
    "$(k get pod "${BUILD_POD}" -o jsonpath='{.spec.volumes[?(@.emptyDir.medium=="Memory")].emptyDir.sizeLimit}')" "2Gi"
  check "build step memory limit" \
    "$(k get pod "${BUILD_POD}" -o jsonpath='{.spec.containers[?(@.name=="step-build")].resources.limits.memory}')" "2Gi"
  build_pvc="$(k get pod "${BUILD_POD}" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}')"
  if [[ -n "${IMAGE_POD}" ]]; then
    check "both tasks mount the same PVC" \
      "$(k get pod "${IMAGE_POD}" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}')" "${build_pvc}"
  fi
  echo
  echo "==> Files handed to the image build (copy step)"
  k logs "${BUILD_POD}" -c step-copy 2>/dev/null | sed 's/^/    /' || true
else
  echo "  FAIL  clone-build pod not found"
  fails=$((fails + 1))
fi

if [[ "${status}" != "True" ]]; then
  echo
  echo "==> Run did not succeed: $(k get pipelinerun "${RUN}" -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}' 2>/dev/null || true)"
  for tr in $(k get taskrun -l "tekton.dev/pipelineRun=${RUN}" -o jsonpath='{range .items[?(@.status.conditions[0].status=="False")]}{.metadata.name}{"\n"}{end}'); do
    echo "--- last log lines of ${tr}"
    k logs "${tr}-pod" --all-containers --tail=15 2>/dev/null | sed 's/^/    /' || true
  done
  if [[ -n "${IMAGE_POD}" ]] && k logs "${IMAGE_POD}" --all-containers 2>/dev/null | grep -q 'COPY pom.xml'; then
    echo
    echo "    Hint: revision '${REVISION}' still has the old multi-stage Dockerfile."
    echo "    Push the runtime-only Dockerfile and pass that branch or SHA as the revision."
  fi
fi

echo
if (( fails == 0 )); then
  echo "RESULT: OK (${RUN})"
  [[ "${CLEANUP}" == "1" ]] && k delete pipelinerun "${RUN}"
  exit 0
fi
echo "RESULT: ${fails} check(s) failed (${RUN})"
echo "Inspect: tkn pr logs ${RUN} -n ${NAMESPACE}   Delete: kubectl -n ${NAMESPACE} delete pipelinerun ${RUN}"
exit 1
