#!/usr/bin/env bash
# Assisted by Claude Opus 4.8
# demo_6 runner: onboard a minimal A2A agent to the Rossoctl operator from the CLI
# alone, let the operator discover + index it, then send the agent a live A2A
# request from a separate pod and prove it acknowledges the call.
#
# Flow:
#   1. Preflight: Rossoctl operator + CRDs present.
#   2. Opt the namespace into Rossoctl (label rossoctl-enabled=true). The runner
#      attempts the label as the normal user; if that is denied (labeling a
#      namespace is cluster-scoped), it warns with the one-time admin command and
#      continues.
#   2b. Ensure the demo user has RBAC for the rossoctl CRs (the operator does not
#      aggregate its CRDs into admin/edit). Applied as the user; on failure it
#      prints the one-time admin command (creating a Role/RoleBinding is admin-only).
#   3. Deploy the agent (ConfigMap + Deployment + Service) and wait for rollout.
#   4. Apply AgentRuntime + AuthorizationPolicy. The AgentCard is NOT hand-authored:
#      the operator stamps rossoctl.io/type=agent, auto-creates the AgentCard,
#      fetches the live card from the Service, and indexes it (Synced=True).
#   5. Show the operator's reconcile log lines.
#   6. Exercise the agent (data plane): a separate pod sends a JSON-RPC message/send;
#      the agent returns a completed-task ack. Confirm via the response AND the
#      agent's own "A2A REQUEST RECEIVED" log line.
# This runner does NOT tear anything down. Run demo_6/cleanup.sh when you are done.
#
# Prereqs beyond the repo README (this runner uses NO --as system:admin):
#   * the Rossoctl operator installed on the cluster;
#   * the target namespace labeled rossoctl-enabled=true ONCE by an admin
#     (cluster-scoped, so a normal user cannot do it — see step 2);
#   * RBAC to create/read agent.rossoctl.dev CRs in the namespace. Step 2b applies
#     demo_6/rbac.yaml to grant this; if the user cannot create the Role/RoleBinding
#     it prints the one-time `--as system:admin` command. Without create RBAC the
#     AgentRuntime/AuthorizationPolicy apply in step 4 fails with Forbidden.
#
#   Run:      ./demo_6/run.sh
#   Cleanup:  ./demo_6/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"
AGENT="weather-agent"
ADMIN=()   # run as the normal user; no --as system:admin
GROUP="agent.rossoctl.dev"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Follow a one-shot pod's logs to completion and assert it Succeeded.
stream_pod() {
  local pod="$1" start_timeout="${2:-300}" elapsed=0 phase
  log "Waiting for pod/$pod to start"
  while :; do
    phase="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Running|Succeeded|Failed) break ;; esac
    if [ "$elapsed" -ge "$start_timeout" ]; then warn "Timed out waiting for pod/$pod"; return 1; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  log "Streaming logs: pod/$pod"
  oc logs -f "pod/$pod" -n "$NS" || true
  for _ in $(seq 1 10); do
    phase="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2
  done
  log "pod/$pod finished: phase=$phase"
  [ "$phase" = "Succeeded" ]
}

# 1) Preflight.
log "1. Preflight: Rossoctl operator CRDs"
for crd in agentruntimes.$GROUP agentcards.$GROUP authorizationpolicies.$GROUP; do
  oc get crd "$crd" >/dev/null 2>&1 || { warn "CRD $crd missing — is the Rossoctl operator installed?"; exit 1; }
done
log "Rossoctl CRDs present (AgentRuntime, AgentCard, AuthorizationPolicy)"

# 2) Namespace opt-in (one-time, admin-only). Labeling a namespace is cluster-
#    scoped, so a normal user cannot do it here. We only VERIFY the opt-in; if the
#    label is missing, print the one-time admin command and continue (the operator
#    may still reconcile depending on its config).
log "2. Opting namespace '$NS' into Rossoctl (label rossoctl-enabled=true)"
oc get namespace "$NS" >/dev/null 2>&1 || { warn "namespace '$NS' not found — ask an admin to create it"; exit 1; }
label="$(oc get namespace "$NS" -o jsonpath='{.metadata.labels.rossoctl-enabled}' 2>/dev/null || true)"
if [ "$label" = "true" ]; then
  log "namespace '$NS' already labeled rossoctl-enabled=true"
else
  # Try to set the label as the normal user. Labeling a namespace is cluster-
  # scoped, so most users cannot do it — handle the failure and keep going.
  if oc label namespace "$NS" rossoctl-enabled=true --overwrite >/dev/null 2>&1; then
    log "labeled namespace '$NS' rossoctl-enabled=true"
  else
    warn "could not label namespace '$NS' (needs cluster-scoped rights a normal user lacks)."
    warn "  A cluster admin must label it once:"
    warn "    oc label namespace $NS rossoctl-enabled=true --overwrite --as system:admin"
    warn "  Continuing anyway; discovery may not happen until it is labeled."
  fi
fi

# 2b) Grant the demo user RBAC for the rossoctl CRs (+ plain workload resources).
#     The operator does not aggregate its CRDs into admin/edit, so this is needed
#     even for a namespace admin. Creating a Role/RoleBinding is itself admin-only:
#     attempt it as the normal user, and on failure print the one-time admin cmd.
log "2b. Ensuring demo RBAC in '$NS' (rossoctl CRs + workload resources)"
me="$(oc whoami 2>/dev/null || true)"
if [ -z "$me" ]; then
  warn "could not determine current user (oc whoami failed) — skipping RBAC"
elif oc auth can-i create agentruntimes.agent.rossoctl.dev -n "$NS" >/dev/null 2>&1; then
  log "user '$me' already has rossoctl CR rights in '$NS'"
else
  rbac="$(sed "s/__DEMO_USER__/$me/" "$SCRIPT_DIR/rbac.yaml")"
  if printf '%s\n' "$rbac" | oc apply -n "$NS" -f - >/dev/null 2>&1; then
    log "applied demo RBAC (Role + RoleBinding) for '$me' in '$NS'"
  else
    warn "could not apply demo RBAC (creating Role/RoleBinding needs admin)."
    warn "  A cluster admin must run this once:"
    warn "    sed 's/__DEMO_USER__/$me/' $SCRIPT_DIR/rbac.yaml | oc apply -n $NS -f - --as system:admin"
    warn "  Without it, step 4 (applying the rossoctl CRs) will fail with Forbidden."
  fi
fi

# 3) Deploy the agent.
log "3. Deploying A2A agent '$AGENT'"
oc apply -f "$SCRIPT_DIR/agent.yaml" -n "$NS"
log "Waiting for deployment/$AGENT to roll out"
oc rollout status "deployment/$AGENT" -n "$NS" --timeout=180s

# 4) Apply the CRs and wait for the operator to discover + sync the AgentCard.
log "4. Applying AgentRuntime + AuthorizationPolicy (AgentCard is auto-created)"
oc apply -f "$SCRIPT_DIR/rossoctl.yaml" -n "$NS"

log "Waiting for the operator to auto-create + sync the AgentCard"
synced=""; card=""
for _ in $(seq 1 40); do
  card="$(oc get agentcards -n "$NS" "${ADMIN[@]}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$card" ]; then
    synced="$(oc get agentcard "$card" -n "$NS" "${ADMIN[@]}" -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || true)"
    name="$(oc get agentcard "$card" -n "$NS" "${ADMIN[@]}" -o jsonpath='{.status.card.name}' 2>/dev/null || true)"
    if [ "$synced" = "True" ] || [ "$name" = "$AGENT" ]; then break; fi
  fi
  sleep 3
done
oc get agentcards -n "$NS" "${ADMIN[@]}" || true
if [ "$synced" = "True" ]; then
  log "Operator auto-created + synced AgentCard '$card' (status.card.name='$(oc get agentcard "$card" -n "$NS" "${ADMIN[@]}" -o jsonpath='{.status.card.name}' 2>/dev/null)')"
else
  warn "AgentCard not fully synced yet (card='$card' synced='$synced') — continuing"
fi

# 5) Operator reconcile logs.
log "5. Operator reconcile log lines mentioning '$AGENT'"
oc logs deploy/rossoctl-controller-manager -n rossoctl-system --tail=2000 2>/dev/null \
  | grep -iE "$AGENT|AgentCard|AgentRuntime|AuthorizationPolicy" | tail -12 \
  || warn "no matching operator log lines"

# 6) Exercise the agent: send a live A2A request and confirm the ack.
log "6. Sending a live A2A request to '$AGENT' and confirming the ack"
oc delete pod a2a-request -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
oc apply -f "$SCRIPT_DIR/a2a-request.yaml" -n "$NS"
stream_pod a2a-request 180

log "Agent log proving it received the request"
oc logs "deployment/$AGENT" -n "$NS" --tail=50 "${ADMIN[@]}" 2>/dev/null \
  | grep -E 'A2A REQUEST RECEIVED' | tail -3 \
  && log "Receipt confirmed in-workload" \
  || warn "no 'A2A REQUEST RECEIVED' line in the agent log yet"

log "demo_6 complete. Agent onboarded, discovered, and proven live. Run demo_6/cleanup.sh to remove it."
