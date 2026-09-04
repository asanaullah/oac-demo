#!/usr/bin/env bash
# Assisted by Claude Opus
# demo_2 runner: serve Gemma 4 with KServe + vLLM on 2xH100 (TP=2), then exercise the
# live endpoint two ways — a network load test and a multimodal (vision) query.
#
# Flow:
#   1. Deploy the serving overlay (ServingRuntime + InferenceService) and wait for the
#      gemma4 InferenceService to report Ready (vLLM loads the 31B weights — minutes).
#   2. inference-perf: constant-rate load test from a SEPARATE pod; stream its report.
#   3. image-query: base64 a staged math image and have Gemma 4 transcribe it to LaTeX.
# This runner does NOT tear anything down. The endpoint stays UP (GPUs stay reserved) so
# you can keep testing it. Run demo_2/cleanup.sh when you are done to free the GPUs.
#
#   Run:      ./demo_2/run.sh
#   Cleanup:  ./demo_2/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Follow a one-shot pod's logs to completion and assert it Succeeded.
stream_pod() {
  local pod="$1" start_timeout="${2:-600}" elapsed=0 phase
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

# Resolve the first pod name matching a label selector (waits for it to appear).
pod_by_label() {
  local selector="$1" start_timeout="${2:-120}" elapsed=0 name
  while :; do
    name="$(oc get pods -n "$NS" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$name" ] && { echo "$name"; return 0; }
    if [ "$elapsed" -ge "$start_timeout" ]; then return 1; fi
    sleep 2; elapsed=$((elapsed + 2))
  done
}

# 1) Serve Gemma 4.
log "Deploying serving overlay (ServingRuntime + InferenceService)"
oc apply -k "$SCRIPT_DIR/overlays/demo" -n "$NS"

log "Waiting for InferenceService/gemma4 to become Ready (vLLM load on 2xH100, up to 20m)"
oc wait --for=condition=Ready "inferenceservice/gemma4" -n "$NS" --timeout=1200s
log "Endpoint is Ready:"
oc get inferenceservice gemma4 -n "$NS"

# 2) Load test from a separate pod.
log "Launching inference-perf load test (8 req/s for 10s)"
oc apply -f "$SCRIPT_DIR/inference-perf.yaml" -n "$NS"
perf_pod="$(pod_by_label 'app=gemma4-inference-perf' 180)" || { warn "inference-perf pod never appeared"; exit 1; }
stream_pod "$perf_pod" 300

# 3) Multimodal query.
log "Launching image-query (Gemma 4 vision: transcribe a math image to LaTeX)"
oc apply -f "$SCRIPT_DIR/image-query.yaml" -n "$NS"
stream_pod "image-query" 180

log "demo_2 complete. Endpoint is still UP. Run demo_2/cleanup.sh to free the GPUs."
