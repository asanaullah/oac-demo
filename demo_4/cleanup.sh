#!/usr/bin/env bash
# Assisted by Claude Opus
# Full cleanup of demo_4 resources: the RayJob (cascades to its ephemeral RayCluster head +
# GPU worker pod, freeing the GPUs) plus the generated driver-script ConfigMap.
# shutdownAfterJobFinishes usually tears the cluster down on its own once the job finishes;
# this is the belt-and-suspenders cleanup (e.g. if the job is still running or was left up).
set -euo pipefail

NAMESPACE="${NAMESPACE:-oac-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Deleting RayJob + script ConfigMap (frees GPUs) ---"
oc delete -k "$SCRIPT_DIR/overlays/demo" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting adapter-inspect pod ---"
oc delete -f "$SCRIPT_DIR/inspect-adapter.yaml" -n "$NAMESPACE" --ignore-not-found

echo "=== Cleanup complete ==="
