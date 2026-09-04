#!/usr/bin/env bash
# Assisted by Claude Opus
# demo_5 runner: serve Qwen2.5-3B-Instruct with KServe + vLLM on a SINGLE H100, with the
# two LoRA adapters from demo_3 (kubeflow) and demo_4 (kuberay) hot-loaded via vLLM
# multi-LoRA. Then run an in-cluster query pod that sends the SAME prompt to all three
# model ids and prints each reply, so base vs. fine-tuned behaviour is visible.
#
# Flow:
#   1. Deploy the serving overlay (ServingRuntime + InferenceService) and wait for the
#      qwen InferenceService to report Ready (vLLM loads the base weights + both adapters).
#   2. query-adapters: a one-shot pod that curls the predictor Service for qwen-base,
#      kubeflow, and kuberay with the same prompt; stream its output.
# This runner does NOT tear anything down — the endpoint stays UP (GPU stays reserved) so
# you can keep poking at it. Run demo_5/cleanup.sh when you're done to free the GPU.
#
#   Run:      ./demo_5/run.sh
#   Cleanup:  ./demo_5/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"
ISVC="qwen"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Follow a one-shot pod's logs to completion and report its final phase.
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
  # `oc logs -f` can return a beat before the pod phase flips to its terminal value; poll
  # briefly so we don't misread a Succeeded pod as still Running.
  for _ in $(seq 1 10); do
    phase="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2
  done
  log "pod/$pod finished: phase=$phase"
  [ "$phase" = "Succeeded" ]
}

# 1) Serve Qwen + adapters.
log "Deploying serving overlay (ServingRuntime + InferenceService, single H100, multi-LoRA)"
oc apply -k "$SCRIPT_DIR/overlays/demo" -n "$NS"

log "Waiting for InferenceService/$ISVC to become Ready (vLLM loads base + 2 adapters, up to 20m)"
oc wait --for=condition=Ready "inferenceservice/$ISVC" -n "$NS" --timeout=1200s
log "Endpoint is Ready:"
oc get inferenceservice "$ISVC" -n "$NS"

# 2) Query base + both adapters from an in-cluster pod (no port-forward required).
log "Launching query-adapters (same prompt -> qwen-base, kubeflow, kuberay)"
oc delete -f "$SCRIPT_DIR/query-adapters.yaml" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
oc apply -f "$SCRIPT_DIR/query-adapters.yaml" -n "$NS"
stream_pod "query-adapters" 180

log "demo_5 complete — endpoint is still UP. Run demo_5/cleanup.sh to free the GPU."
