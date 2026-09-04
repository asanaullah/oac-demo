#!/usr/bin/env bash
# Assisted by Claude Opus
# Full cleanup of demo_3 resources: the PyTorchJob (cascades to its worker pods and frees
# the GPUs) plus the generated training-script ConfigMap.
set -euo pipefail

NAMESPACE="${NAMESPACE:-oac-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Deleting PyTorchJob + script ConfigMap (frees GPUs) ---"
oc delete -k "$SCRIPT_DIR/overlays/demo" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting adapter-inspect pod ---"
oc delete -f "$SCRIPT_DIR/inspect-adapter.yaml" -n "$NAMESPACE" --ignore-not-found

echo "=== Cleanup complete ==="
