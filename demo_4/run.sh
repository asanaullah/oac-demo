#!/usr/bin/env bash
# Assisted by Claude Opus
# demo_4 runner: the same Qwen2.5-3B LoRA fine-tune as demo_3, but distributed with a
# KubeRay RayJob + Ray Train across 4xH100 (one worker pod, 4 actors). Then inspect the
# adapter it writes to the results PVC.
#
# Flow:
#   1. Apply the overlay (RayJob qwen-sft-ray + the driver-script ConfigMap). KubeRay stands
#      up an ephemeral Ray cluster (CPU head + 1 GPU worker pod holding all 4 H100s).
#   2. Once the cluster is Ready, KubeRay creates a submitter Job (named qwen-sft-ray) that
#      runs the driver. Follow its logs live: runtime-env pip install, then NCCL init and the
#      loss/eval/perplexity from the Ray Train workers.
#   3. Wait for the RayJob's jobStatus to settle (SUCCEEDED/FAILED). shutdownAfterJobFinishes
#      tears the cluster down and frees the GPUs automatically.
#   4. adapter-inspect: print the LoRA adapter written to /mnt/results/kuberay.
# This runner does NOT clean up. shutdownAfterJobFinishes already tears the Ray cluster
# down and frees the GPUs when the job ends, but the RayJob CR + ConfigMap + inspect pod
# are left in place. Run demo_4/cleanup.sh when you are done to remove them.
#
#   Run:      ./demo_4/run.sh
#   Cleanup:  ./demo_4/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"
RAYJOB="qwen-sft-ray"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Follow a one-shot pod's logs to completion and assert it Succeeded.
stream_pod() {
  local pod="$1" start_timeout="${2:-900}" elapsed=0 phase
  log "Waiting for pod/$pod to start"
  while :; do
    phase="$(oc get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Running|Succeeded|Failed) break ;; esac
    if [ "$elapsed" -ge "$start_timeout" ]; then warn "Timed out waiting for pod/$pod"; return 1; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  log "Streaming logs: pod/$pod"
  oc logs -f "pod/$pod" -n "$NS" || true
}

# The submitter pod belongs to a batch Job named after the RayJob (not the app=... label the
# head/worker pods carry). Try the modern job label, then the legacy one.
submitter_pod() {
  local start_timeout="${1:-900}" elapsed=0 name
  while :; do
    name="$(oc get pods -n "$NS" -l "batch.kubernetes.io/job-name=$RAYJOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -z "$name" ] && name="$(oc get pods -n "$NS" -l "job-name=$RAYJOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$name" ] && { echo "$name"; return 0; }
    if [ "$elapsed" -ge "$start_timeout" ]; then return 1; fi
    sleep 4; elapsed=$((elapsed + 4))
  done
}

# 1) Launch the RayJob.
log "Deploying KubeRay RayJob overlay ($RAYJOB + driver-script ConfigMap)"
oc apply -k "$SCRIPT_DIR/overlays/demo" -n "$NS"

# 2) Wait for the submitter pod (cluster init + head runtime-env can take several minutes),
#    then stream the driver logs.
log "Waiting for the RayJob submitter pod (cluster init on 4xH100 + runtime-env install)"
sub="$(submitter_pod 900)" || { warn "Submitter pod never appeared"; oc get rayjob "$RAYJOB" -n "$NS"; exit 1; }
stream_pod "$sub" 900

# 3) Settle the RayJob status. (The driver log ending precedes the CR status flip by seconds.)
log "Waiting for RayJob jobStatus to settle"
status=""; elapsed=0
while :; do
  status="$(oc get rayjob "$RAYJOB" -n "$NS" -o jsonpath='{.status.jobStatus}' 2>/dev/null || true)"
  case "$status" in SUCCEEDED|FAILED) break ;; esac
  if [ "$elapsed" -ge 120 ]; then break; fi
  sleep 5; elapsed=$((elapsed + 5))
done
log "RayJob jobStatus=$status"
[ "$status" = "SUCCEEDED" ] || { warn "RayJob did not succeed"; exit 1; }

# 4) Inspect the adapter. shutdownAfterJobFinishes has freed the GPUs; the PVC persists.
log "Inspecting the LoRA adapter written to /mnt/results/kuberay"
oc apply -f "$SCRIPT_DIR/inspect-adapter.yaml" -n "$NS"
stream_pod "adapter-inspect-ray" 180

log "demo_4 complete. Ray Train fine-tune finished and adapter verified on the results PVC. Run demo_4/cleanup.sh to remove the RayJob."
