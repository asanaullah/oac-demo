# Demo

## Model downloader
- [ ] Request model storage (PVC and S3)
- [ ] Download three models (Gemma 4 + Granite or Qwen for fine tuning)
- [ ] Mount the PVC to `/models` on an example pod
- [ ] Demo that the models are visible from within the pod

## Result and Dataset storage
- [ ] PVC and/or S3 (or one example of each?)

## Model Serving w/ KServe
- [ ] Use KServe + vLLM + 2xH100 (TP==2) to serve a Gemma 4 model
- [ ] Test the endpoint from a separate pod running inference-perf or guidellm

## Fine tuning w/ Kubeflow
- [ ] Use Kubeflow (PyTorchJob) to deploy a finetuning job on 4xH100
- [ ] Load base model from model storage
- [ ] Load dataset from dataset storage
- [ ] Tune the model using HF SFTTrainer
- [ ] Store LoRA adapter in results storage

## Fine tuning w/ KubeRay
- [ ] Use KubeRay (RayTrain) to deploy a finetuning job on 4xH100
- [ ] Load base model from model storage
- [ ] Load dataset from dataset storage
- [ ] Tune the model using HF SFTTrainer
- [ ] Store LoRA adapter in results storage

## Model Serving w/ vLLM Multi-Lora
- [ ] Use vLLM + 1xH100 to serve the base model + the two trained adapters
- [ ] Deploy service so that the endpoint is visible
- [ ] Test the base model + adapters using the same prompt
