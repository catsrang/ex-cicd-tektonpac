#!/usr/bin/env bash
# Phase 2: create the cluster Secret PAC reads to authenticate as the GitHub App.
# Run this AFTER the App exists (Option A or B in README.md) and you have:
#   - the App ID
#   - the downloaded private key .pem file
#   - the webhook secret you generated when creating the App
#
# Usage:
#   APP_ID=123456 \
#   PRIVATE_KEY_PATH=/path/to/downloaded-key.pem \
#   WEBHOOK_SECRET='...' \
#   ./create-secret.sh
#
# Never commit the .pem file or webhook secret value to git.
set -euo pipefail

NAMESPACE="pipelines-as-code"
SECRET_NAME="pipelines-as-code-secret"

: "${APP_ID:?Set APP_ID to the GitHub App numeric ID}"
: "${PRIVATE_KEY_PATH:?Set PRIVATE_KEY_PATH to the downloaded .pem file path}"
: "${WEBHOOK_SECRET:?Set WEBHOOK_SECRET to the webhook secret configured on the App}"

if [[ ! -f "${PRIVATE_KEY_PATH}" ]]; then
  echo "ERROR: private key file not found at ${PRIVATE_KEY_PATH}" >&2
  exit 1
fi

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-file="github-private-key=${PRIVATE_KEY_PATH}" \
  --from-literal="github-application-id=${APP_ID}" \
  --from-literal="webhook.secret=${WEBHOOK_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret '${SECRET_NAME}' applied in namespace '${NAMESPACE}'."
