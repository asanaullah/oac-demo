# OAC End-User Demos

A walkthrough of an example OAC end-user workflow: stand up storage, stage models and datasets, serve a model, fine-tune a model two different ways, and serve the tuned adapters.

## Prerequisites

- An OpenShift cluster with NVIDIA H100 GPU nodes and the KServe, Kubeflow Training Operator, and KubeRay operators installed.
- The `oc` CLI installed and logged in to the cluster with permission to create the resources in each demo.
- Run the demos in order. Demo 0 and Demo 1 lay down the namespace, storage, models, and datasets that every later demo reads from the shared PVCs.

## Running the demos

Each demo lives in its own folder and ships a `run.sh` that drives the whole flow: it applies the manifests, waits for the workload to become Ready, streams the logs, and (for the serving and training demos) runs a small step to exercise or inspect the result.

The runners do **not** tear anything down, so serving and training workloads stay up until you run the demo's `cleanup.sh`. Demos 2 through 5 hold H100s for as long as their workloads run: demos 2, 3, and 5 keep their GPUs reserved until `cleanup.sh` (demo 3's training pods linger after the job completes), while demo 4 frees its GPUs automatically when the RayJob finishes.

## Demo 0: Namespace & Storage (admin)

- Create the `oac-demo` namespace, ServiceAccount, and RBAC.
- Create the `models`, `datasets`, and `results` PVCs (RWX, `pure-fb-nfsv4`).

```sh
./demo_0/run.sh
```

## Demo 1: Model and dataset downloader

- Download two base models (Gemma 4 and Qwen2.5-3B-Instruct) onto the `models` PVC.
- Download the fine-tuning and inference datasets (alpaca and LaTeX_OCR) onto the `datasets` PVC.
- Verify from inside a pod that the staged models and datasets are visible and readable.

```sh
./demo_1/run.sh
./demo_1/cleanup.sh   # removes the downloader/verify pods (PVC data stays)
```

## Demo 2: Model Serving w/ KServe

- Serve Gemma 4 with KServe + vLLM on 2xH100 (tensor-parallel size 2).
- Load the weights from the `models` PVC.
- Run a constant-rate load test from a separate pod (inference-perf).
- Exercise the multimodal path: have the model transcribe a math image to LaTeX.

```sh
./demo_2/run.sh
./demo_2/cleanup.sh   # deletes the endpoint (frees the GPUs)
```

## Demo 3: Fine tuning w/ Kubeflow

- Run a LoRA fine-tune of Qwen2.5-3B on the alpaca dataset with a Kubeflow PyTorchJob across 4xH100.
- Load the base model and dataset from their PVCs.
- Tune with the HF SFTTrainer, distributed with torchrun/DDP.
- Write the LoRA adapter to the `results` PVC under `kubeflow/`, then inspect it.

```sh
./demo_3/run.sh
./demo_3/cleanup.sh   # deletes the training job (frees the GPUs)
```

## Demo 4: Fine tuning w/ KubeRay

- Run the same LoRA fine-tune with a KubeRay RayJob (Ray Train) across 4xH100.
- Load the base model and dataset from their PVCs.
- Tune with the HF SFTTrainer, distributed by Ray Train's TorchTrainer.
- Write the LoRA adapter to the `results` PVC under `kuberay/`, then inspect it.

```sh
./demo_4/run.sh
./demo_4/cleanup.sh   # removes the RayJob (GPUs already freed by the job)
```

## Demo 5: Model Serving w/ vLLM Multi-Lora

- Serve Qwen2.5-3B plus both trained adapters with KServe + vLLM on a single H100 (vLLM multi-LoRA).
- Register the base model and the `kubeflow` and `kuberay` adapters as separate model ids.
- Send the same prompt to all three from an in-cluster pod and compare the replies, so the base model and the two fine-tuned adapters can be seen side by side.

```sh
./demo_5/run.sh
./demo_5/cleanup.sh   # deletes the endpoint (frees the GPU)
```
