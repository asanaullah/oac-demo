#!/usr/bin/env bash
# Assisted by Claude Opus 4.8
# Full cleanup of demo_6 resources:
#   - the a2a-request client pod
#   - the Rossoctl CRs (AgentRuntime + AuthorizationPolicy; the operator's
#     auto-created AgentCard is garbage-collected with them)
#   - the agent workload (ConfigMap + Deployment + Service)
# The namespace and its rossoctl-enabled label are left in place: the namespace is
# shared by the other demos, and unlabeling it is a cluster-scoped, admin-only op.
set -euo pipefail

NAMESPACE="${NAMESPACE:-oac-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "--- Deleting a2a-request pod ---"
oc delete -f "$SCRIPT_DIR/a2a-request.yaml" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting Rossoctl CRs (AgentRuntime + AuthorizationPolicy) ---"
oc delete -f "$SCRIPT_DIR/rossoctl.yaml" -n "$NAMESPACE" --ignore-not-found

echo "--- Deleting agent workload (ConfigMap + Deployment + Service) ---"
oc delete -f "$SCRIPT_DIR/agent.yaml" -n "$NAMESPACE" --ignore-not-found

echo "=== Cleanup complete ==="
