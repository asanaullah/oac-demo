#!/usr/bin/env bash
# Assisted by Claude Opus
# demo_3 runner: LoRA fine-tune Qwen2.5-3B on alpaca across 4xH100 with a Kubeflow
# PyTorchJob (SFTTrainer/DDP), then inspect the adapter it writes to the results PVC.
#
# Flow:
#   1. Apply the overlay (PyTorchJob qwen-sft + the training-script ConfigMap).
#   2. Follow the master pod's logs live: entrypoint.sh installs the training stack, then
#      torchrun runs 4 ranks (one per GPU). Watch for NCCL init + the loss/eval/perplexity.
#   3. adapter-inspect: print the LoRA adapter (r/alpha/target modules) written to
#      /mnt/results/kubeflow.
# This runner does NOT clean up. The PyTorchJob is left in place (GPUs stay reserved until
# deleted). Run demo_3/cleanup.sh when you are done to delete the job and free the GPUs.
#
#   Run:      ./demo_3/run.sh
#   Cleanup:  ./demo_3/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NAMESPACE:-oac-demo}"
MASTER_POD="qwen-sft-master-0"   # Kubeflow names the single Master replica's pod this.

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

# 1) Launch the fine-tune job.
log "Deploying Kubeflow PyTorchJob overlay (qwen-sft + script ConfigMap)"
oc apply -k "$SCRIPT_DIR/overlays/demo" -n "$NS"

# 2) Stream training. Master pod pulls the image + pip-installs the stack before torchrun,
#    so allow a generous start window.
stream_pod "$MASTER_POD" 900

# 3) Inspect the adapter.
log "Inspecting the LoRA adapter written to /mnt/results/kubeflow"
oc apply -f "$SCRIPT_DIR/inspect-adapter.yaml" -n "$NS"
stream_pod "adapter-inspect" 180

log "demo_3 complete. Fine-tune finished and adapter verified on the results PVC. Run demo_3/cleanup.sh to free the GPUs."
