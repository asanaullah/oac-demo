#!/usr/bin/env bash
# Assisted by Claude Opus
# demo_1 runner: stage the models and datasets onto their PVCs, one downloader at a time,
# streaming each pod's logs to completion, then run the verify-models pod to prove the
# weights are visible/readable from inside a pod.
#
# Flow (sequential — each step's logs stream live, and a failure stops the run):
#   1. model-downloader    -> pulls Gemma 4 + Qwen2.5-3B onto the `models` PVC
#   2. dataset-downloader  -> pulls alpaca + LaTeX_OCR (and sample PNGs) onto `datasets`
#   3. verify-models       -> prints metadata for every model found under /mnt/models
# This runner does NOT clean up. The pods are left in place; run demo_1/cleanup.sh when
# you are done to remove them.
#
#   Run:      ./demo_1/run.sh
#   Cleanup:  ./demo_1/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Wait until a one-shot pod has left Pending (container started), then follow its logs to
# completion and assert it Succeeded.
run_pod() {
  local manifest="$1" pod="$2" start_timeout="${3:-600}" elapsed=0 phase
  log "Applying $(basename "$manifest") -> pod/$pod"
  oc apply -f "$manifest" -n "$NS"

  log "Waiting for pod/$pod to start"
  while :; do
    phase="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Running|Succeeded|Failed) break ;;
    esac
    if [ "$elapsed" -ge "$start_timeout" ]; then
      warn "Timed out waiting for pod/$pod to start"; return 1
    fi
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

# 1) Models (large — Gemma 4 ~62Gi + Qwen ~6Gi; allow a long start window for image pull).
run_pod "$SCRIPT_DIR/model-downloader.yaml"   model-downloader

# 2) Datasets (alpaca + LaTeX_OCR + sample image export).
run_pod "$SCRIPT_DIR/dataset-downloader.yaml" dataset-downloader

# 3) Verify the models are visible from a pod (this is the "inspect" step).
run_pod "$SCRIPT_DIR/verify-models.yaml"      verify-models

log "demo_1 complete. Models and datasets are staged and verified. Run demo_1/cleanup.sh to remove the pods."
