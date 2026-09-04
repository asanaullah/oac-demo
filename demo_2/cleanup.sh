#!/usr/bin/env bash
# Assisted by Claude Opus
# Full cleanup of demo_2 resources:
#   - the serving overlay (InferenceService gemma4 + ServingRuntime; cascades to the
#     predictor Deployment/Service/pod and frees the GPUs)
#   - the inference-perf load test (Job + ConfigMap)
#   - the image-query pod
set -euo pipefail

NAMESPACE="${NAMESPACE:-oac-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Deleting serving overlay (isvc + runtime; frees GPUs) ---"
oc delete -k "$SCRIPT_DIR/overlays/demo" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting inference-perf (Job + ConfigMap) ---"
oc delete -f "$SCRIPT_DIR/inference-perf.yaml" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting image-query pod ---"
oc delete -f "$SCRIPT_DIR/image-query.yaml" -n "$NAMESPACE" --ignore-not-found

echo "=== Cleanup complete ==="
