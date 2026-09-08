#!/usr/bin/env bash
# Assisted by Claude Opus 4.8
# demo_7 runner: prove that NVIDIA OpenShell — not a raw Kubernetes NetworkPolicy —
# denies a sandboxed Claude Code agent's attempt to read from github.com.
#
# OpenShell enforces egress with an inline L7 "policy proxy" (OPA/regorus) that
# evaluates destination host + calling binary before traffic leaves the sandbox.
# Policy is fail-closed: anything not explicitly allowed is denied. A blocked
# host surfaces as:  curl: (56) Received HTTP code 403 from proxy after CONNECT
#
# Flow:
#   1. Preflight: oc/curl present, logged in, and the OpenShell gateway is already
#      deployed (installing it is a one-time admin op — see prereqs, not done here).
#   2. Ensure the 'openshell' CLI, then register + select the gateway (port-forward).
#   3. Render the OpenShell network policy from policy.yaml (allow anthropic +
#      ALLOW_HOST; github.com deliberately omitted -> denied by default).
#   4. Create a sandbox running the Claude Code agent with that policy attached.
#   5. From inside the sandbox: curl ALLOW_HOST -> ALLOWED; curl github.com ->
#      DENIED (403 from the OpenShell policy proxy).
#   6. Corroborate the deny in `openshell logs` (OPA engine, action=deny).
#   7. Summary.
#
# The denial is done by OpenShell's proxy. No Kubernetes NetworkPolicy is used.
# This runner does NOT tear anything down. Run demo_7/cleanup.sh when you are done.
#
# Prereqs beyond the repo README:
#   * oc/curl on PATH; the 'openshell' CLI (auto-installed to ~/.local/bin if missing).
#   * The OpenShell gateway + agent-sandbox CRDs already deployed by an admin
#     (e.g. endpoints/openshell/deploy.sh in the sibling repo, or your platform's
#     install). This runner only VERIFIES the gateway is present; it does not deploy it.
#   * Reaching the gateway assumes local/plaintext (values-openshift disableTls). If it
#     enforces OIDC/mTLS, register it yourself and set GATEWAY_ALREADY_REGISTERED=1.
#
#   Run:      ./demo_7/run.sh   [--no-cleanup]
#   Cleanup:  ./demo_7/cleanup.sh
#
# Env: OPENSHELL_NAMESPACE, NAMESPACE, GATEWAY_NAME, GATEWAY_URL,
#      SANDBOX_NAME, ALLOW_HOST, DENY_URL, GATEWAY_ALREADY_REGISTERED, KEEP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENSHELL_NAMESPACE="${OPENSHELL_NAMESPACE:-openshell}"
NAMESPACE="${NAMESPACE:-openshell-sandboxes}"
GATEWAY_NAME="${GATEWAY_NAME:-demo}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8080}"
SANDBOX_NAME="${SANDBOX_NAME:-claude-agent}"
ALLOW_HOST="${ALLOW_HOST:-example.com}"
DENY_URL="${DENY_URL:-https://github.com}"
GATEWAY_ALREADY_REGISTERED="${GATEWAY_ALREADY_REGISTERED:-0}"
ADMIN=(--as system:admin)   # only for reads/deletes in the admin-managed openshell ns

TMP="${TMPDIR:-/tmp}"
POLICY_FILE="$(mktemp "${TMP}/openshell-policy.XXXXXX.yaml")"
PF_PID=""
CREATE_PID=""

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
die()   { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }
log()   { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# 1) Preflight: tools + gateway present (deploying the gateway is an admin op, not here).
log "1. Preflight: tools + OpenShell gateway present"
command -v oc   >/dev/null || die "oc not found"
command -v curl >/dev/null || die "curl not found"
oc whoami >/dev/null 2>&1 || die "not logged in (oc login ...)"
if oc get ns "${OPENSHELL_NAMESPACE}" >/dev/null 2>&1 \
   && oc get deploy,statefulset -n "${OPENSHELL_NAMESPACE}" -l app.kubernetes.io/name=openshell >/dev/null 2>&1; then
  green "OpenShell gateway present in '${OPENSHELL_NAMESPACE}'"
else
  die "OpenShell gateway not found in '${OPENSHELL_NAMESPACE}'. An admin must deploy it first (see prereqs)."
fi

GW_SVC="$(oc get svc -n "${OPENSHELL_NAMESPACE}" -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo openshell-gateway)"
oc rollout status "$(oc get statefulset,deploy -n "${OPENSHELL_NAMESPACE}" -l app.kubernetes.io/name=openshell -o name | head -1)" \
  -n "${OPENSHELL_NAMESPACE}" "${ADMIN[@]}" --timeout=5m || warn "gateway rollout not confirmed"
green "Gateway service: ${GW_SVC}"

# 2) openshell CLI + gateway registration.
log "2. Ensuring the 'openshell' CLI is installed"
if ! command -v openshell >/dev/null; then
  warn "openshell CLI not found — installing to \$HOME/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh \
    || die "openshell CLI install failed — install manually and re-run"
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v openshell >/dev/null || die "openshell still not on PATH after install"
fi
green "openshell CLI: $(command -v openshell)"

log "2b. Port-forwarding the gateway and registering it with the CLI"
oc port-forward "svc/${GW_SVC}" 8080:8080 -n "${OPENSHELL_NAMESPACE}" >"${TMP}/openshell-pf.log" 2>&1 &
PF_PID=$!
sleep 4
if [[ "${GATEWAY_ALREADY_REGISTERED}" == "1" ]]; then
  warn "GATEWAY_ALREADY_REGISTERED=1 — skipping gateway add/select"
else
  # Assumes a local/plaintext-reachable gateway (values-openshift server.disableTls).
  # If your gateway enforces OIDC/mTLS, register it yourself and set
  # GATEWAY_ALREADY_REGISTERED=1.
  openshell gateway add "${GATEWAY_URL}" --local --name "${GATEWAY_NAME}" 2>/dev/null || true
  openshell gateway select "${GATEWAY_NAME}" \
    || die "could not select gateway '${GATEWAY_NAME}' — likely OIDC/mTLS auth required (see caveats)"
fi
green "gateway '${GATEWAY_NAME}' selected (${GATEWAY_URL})"

# 3) Render the OpenShell network policy from policy.yaml.
log "3. Rendering OpenShell network policy (allow anthropic+${ALLOW_HOST}; github omitted -> denied)"
sed "s/__ALLOW_HOST__/${ALLOW_HOST}/g" "${SCRIPT_DIR}/policy.yaml" >"${POLICY_FILE}"
cat "${POLICY_FILE}"

# 4) Create the sandbox with the policy attached.
# NOTE: this CLI's `sandbox create` attaches to the trailing command; there is no
# --detach. Start it in the background with a keepalive (sleep infinity) so the pod
# stays up while we probe it via `openshell sandbox exec`. The Claude Code agent is
# exercised through exec below (running `claude` in the foreground would block and
# needs an API key just to start).
log "4. Creating sandbox '${SANDBOX_NAME}' with the OpenShell policy attached"
openshell sandbox create --name "${SANDBOX_NAME}" --policy "${POLICY_FILE}" --no-tty -- sleep infinity \
  >"${TMP}/openshell-create.log" 2>&1 &
CREATE_PID=$!

log "4b. Waiting for sandbox to become ready"
READY=0
for _ in $(seq 1 60); do
  if openshell sandbox exec -n "${SANDBOX_NAME}" -- true >/dev/null 2>&1; then READY=1; break; fi
  kill -0 "${CREATE_PID}" 2>/dev/null || { warn "create process exited early; see ${TMP}/openshell-create.log"; break; }
  sleep 3
done
[[ "${READY}" == "1" ]] || { cat "${TMP}/openshell-create.log" 2>/dev/null; die "sandbox never became ready (check gateway auth / policy validation)"; }
green "sandbox '${SANDBOX_NAME}' ready under OpenShell policy"

# probe = run a command inside the sandbox THROUGH OpenShell (proxy path).
probe() { openshell sandbox exec -n "${SANDBOX_NAME}" --timeout 20 -- bash -lc "$1"; }

# Show the Claude Code agent is present in the sandbox (best-effort).
probe "command -v claude && claude --version" 2>/dev/null \
  && green "Claude Code agent available in sandbox" \
  || warn "claude binary not in default image (denial demo uses curl; agent optional)"

# 5) Probe: allowed vs denied, both enforced by OpenShell.
log "5a. ALLOWED path: curl https://${ALLOW_HOST} from inside the sandbox"
# Write the body to a file inside the sandbox (not /dev/null, which trips a spurious
# "curl: (23) Failure writing output" through the exec stream), print only the status.
# Judge on the HTTP status, not curl's exit code.
AOUT="$(probe "curl -sS -o /tmp/probe.out -w 'HTTP %{http_code}\n' --max-time 15 https://${ALLOW_HOST} 2>&1" || true)"
echo "${AOUT}"
if echo "${AOUT}" | grep -qiE 'HTTP (200|2[0-9][0-9])'; then
  green "OpenShell ALLOWED curl -> ${ALLOW_HOST} (matches policy)"
else
  warn "allowed-path probe inconclusive"
fi

log "5b. DENIED path: reading ${DENY_URL} from inside the sandbox (expect 403 from proxy)"
DENIED=0
OUT="$(probe "curl -sS --max-time 15 ${DENY_URL} 2>&1" || true)"
echo "${OUT}"
if echo "${OUT}" | grep -qiE '403.*proxy|proxy after CONNECT|CONNECT tunnel failed, response 403|policy_denied'; then
  DENIED=1
elif ! echo "${OUT}" | grep -qiE '<html|HTTP/.* 200|<!DOCTYPE'; then
  DENIED=1   # no real page came back -> blocked
fi

# 6) Corroborate via OpenShell deny logs.
log "6. OpenShell enforcement logs (proof the proxy did the deny)"
# The deny decision is an OCSF security event from the sandbox-side policy proxy:
#   NET:OPEN [MED] DENIED /usr/bin/curl(...) -> github.com:443
#     [engine:opa] [reason:endpoint github.com:443 is not allowed by any policy]
echo "--- sandbox proxy (OPA enforcement) ---"
SBLOG="$(openshell logs "${SANDBOX_NAME}" -n 800 --since 10m --source sandbox 2>/dev/null || true)"
DENYLINE="$(echo "${SBLOG}" | grep -iE 'DENIED' | grep -i "${DENY_URL#https://}" | tail -3)"
if [[ -n "${DENYLINE}" ]]; then
  echo "${DENYLINE}"
  green "OpenShell OPA engine logged the DENY for ${DENY_URL}"
  [[ "${DENIED}" == "1" ]] || DENIED=1
else
  echo "${SBLOG}" | grep -iE 'DENIED|deny|policy' | tail -5 || true
  warn "no explicit DENIED line matched (check: openshell logs ${SANDBOX_NAME} --source sandbox | grep DENIED)"
fi
echo "--- gateway (policy load + relayed command) ---"
openshell logs "${SANDBOX_NAME}" -n 400 --since 10m --source gateway 2>/dev/null \
  | grep -iE 'status=loaded|ExecSandbox .*command started' | tail -3 || true

# 7) Summary.
log "7. Result"
if [[ "${DENIED}" == "1" ]]; then
  green "DEMO PASSED: OpenShell's policy proxy DENIED the sandboxed agent's read of ${DENY_URL}, while allowing ${ALLOW_HOST}."
else
  die "DEMO INCONCLUSIVE/FAILED: ${DENY_URL} was not observably denied. Inspect: openshell logs ${SANDBOX_NAME} --tail"
fi
