#!/usr/bin/env bash
# Assisted by Claude Opus
# Deletes the demo_1 pods (model-downloader, verify-models).
set -euo pipefail

NAMESPACE="${NAMESPACE:-oac-demo}"

for pod in model-downloader verify-models; do
  echo "--- Deleting pod/$pod ---"
  oc delete pod "$pod" -n "$NAMESPACE" --ignore-not-found
done

echo "=== Cleanup complete ==="
