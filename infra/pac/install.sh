#!/usr/bin/env bash
# Phase 1: install Pipelines as Code (PAC) on a vanilla Kubernetes/k3s cluster.
# Requires: kubectl pointed at the target cluster's context.
set -euo pipefail

RELEASE_URL="https://raw.githubusercontent.com/tektoncd/pipelines-as-code/stable/release.k8s.yaml"
NAMESPACE="pipelines-as-code"

echo "Applying PAC release manifest from: ${RELEASE_URL}"
kubectl apply -f "${RELEASE_URL}"

echo "Waiting for PAC deployments to become available in namespace '${NAMESPACE}'..."
kubectl -n "${NAMESPACE}" wait --for=condition=Available --timeout=180s deployment --all

echo "Done. Run ./verify.sh to inspect status."
