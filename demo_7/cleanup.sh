#!/usr/bin/env bash
# Assisted by Claude Opus 4.8
# Cleanup demo_7: delete the OpenShell sandbox created by run.sh.
#
# The OpenShell gateway, agent-sandbox CRDs, and the openshell/openshell-sandboxes
# namespaces are left in place: they are cluster-scoped, admin-managed, and shared.
# To fully remove OpenShell, uninstall its Helm release and delete those namespaces
# as an admin.
set -euo pipefail

SANDBOX_NAME="${SANDBOX_NAME:-claude-agent}"
NAMESPACE="${NAMESPACE:-openshell-sandboxes}"

echo "--- Deleting OpenShell sandbox '${SANDBOX_NAME}' ---"
openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null \
  || oc delete sandbox "${SANDBOX_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null \
  || true

echo "=== Cleanup complete ==="
