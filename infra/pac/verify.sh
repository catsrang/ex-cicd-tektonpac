#!/usr/bin/env bash
# Phase 1: verify the PAC controller/webhook/watcher are all healthy.
set -euo pipefail

NAMESPACE="pipelines-as-code"

echo "Deployments in namespace '${NAMESPACE}':"
kubectl get deployment -n "${NAMESPACE}"

echo
echo "Pods in namespace '${NAMESPACE}':"
kubectl get pods -n "${NAMESPACE}"
