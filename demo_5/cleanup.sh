#!/usr/bin/env bash
# Assisted by Claude Opus
# Full cleanup of demo_5 resources:
#   - the query-adapters pod
#   - the serving overlay (InferenceService qwen + ServingRuntime qwen-vllm-runtime).
#     Deleting the InferenceService cascades to the predictor Deployment/Service/pod and
#     frees the GPU.
set -euo pipefail

NAMESPACE="${NAMESPACE:-oac-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Deleting query-adapters pod ---"
oc delete -f "$SCRIPT_DIR/query-adapters.yaml" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting serving overlay (isvc + runtime; frees the GPU) ---"
oc delete -k "$SCRIPT_DIR/overlays/demo" -n "$NAMESPACE" --ignore-not-found

echo "=== Cleanup complete ==="
