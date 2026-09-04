#!/usr/bin/env bash
# Assisted by Claude Opus 4.8
# demo_0 runner: create the namespace, PVCs, ServiceAccount and RBAC that every other
# demo depends on. This is a one-shot `apply` of foundational, long-lived resources —
# there is deliberately NO cleanup step here (tearing the namespace/PVCs down would
# delete the storage the later demos rely on).
#
#   Run:  ./demo_0/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Applying namespace, PVCs, ServiceAccount and RBAC"
oc apply -f "$SCRIPT_DIR/namespaces-and-pvcs.yaml"

log "Namespace"
oc get namespace "$NS"

log "PVCs in $NS (RWX pure-fb-nfsv4)"
oc get pvc -n "$NS"

log "ServiceAccount / Role / RoleBinding in $NS"
oc get serviceaccount,role,rolebinding -n "$NS" 2>/dev/null | grep -Ei 'oac-demo' || true

log "demo_0 complete — foundation is in place. (No cleanup: these resources are permanent.)"
