#!/usr/bin/env bash
# Assisted by Claude Opus
# Container entrypoint for the fine-tune job. Mounted into the PyTorchJob from the same
# ConfigMap as the training script and invoked as `bash /scripts/entrypoint.sh`.
#
# It installs the HF training stack (nothing is baked into a custom image) and then hands
# off to torchrun. The process/GPU count is NOT set here: it comes from the PyTorchJob
# (spec.nprocPerNode -> PET_NPROC_PER_NODE), which torchrun reads as its default.
set -euo pipefail

# The pod runs as a random non-root UID (OpenShift restricted SCC), so neither the global
# site-packages nor the default ~/.local ($HOME=/) is writable. Point HOME/PYTHONUSERBASE
# at /tmp and do a --user install: unlike --target, a user install still sees the base
# image's packages, so torch (already in the image, matching torchrun) is NOT reinstalled.
# The exported vars are inherited by the torchrun worker processes.
export HOME=/tmp
export PYTHONUSERBASE=/tmp/pip-user

# Pinned to match the proven ost fine-tuning reference (torch comes from the base image).
pip install --no-cache-dir --user \
  "transformers==4.46.3" \
  "datasets==2.21.0" \
  "accelerate==1.1.1" \
  "peft==0.13.2" \
  "trl==0.12.1" \
  sentencepiece protobuf

exec torchrun "/scripts/${SCRIPT_NAME}"
