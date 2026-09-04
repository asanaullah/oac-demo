# Assisted by Claude Opus
# Ray Train version of the demo_3 fine-tune: the same LoRA SFT of Qwen2.5-3B, but
# distributed by Ray Train's TorchTrainer (on a KubeRay cluster) instead of a Kubeflow
# PyTorchJob.
#
# Ray Train owns the scaling: TorchTrainer(num_workers=4, use_gpu=True) launches one worker
# actor per GPU, sets up the torch process group (NCCL backend) across them, and runs
# train_func on each. The HF SFTTrainer inside train_func does the actual LoRA fine-tune;
# Ray Train just provides the distributed wiring (it exports RANK/WORLD_SIZE/LOCAL_RANK/
# MASTER_ADDR so the HF Trainer's own DDP latches onto the group Ray already created).
#
# Paths / hyper-parameters come from env vars (set on the worker pod; Ray actors inherit
# the container env). Model + dataset are staged locally by demo_1; adapter -> results PVC.
import glob
import math
import os

import ray
from ray.train import ScalingConfig, RunConfig
from ray.train.torch import TorchTrainer


def train_func(config):
    # Imports happen on the worker, where the Ray runtime-env pip packages are available.
    import torch
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments
    from peft import LoraConfig
    from trl import SFTTrainer
    from ray import train
    from ray.train.huggingface.transformers import prepare_trainer, RayTrainReportCallback

    MODEL_PATH = os.environ["MODEL_PATH"]
    DATASET_PATH = os.environ["DATASET_PATH"]
    OUTPUT_DIR = os.environ["OUTPUT_DIR"]
    MAX_STEPS = int(os.environ.get("MAX_STEPS", "60"))
    EVAL_SAMPLES = int(os.environ.get("EVAL_SAMPLES", "200"))
    LEARNING_RATE = float(os.environ.get("LEARNING_RATE", "2e-4"))
    BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "8"))
    LORA_RANK = int(os.environ.get("LORA_RANK", "16"))
    MAX_SEQ_LENGTH = int(os.environ.get("MAX_SEQ_LENGTH", "2048"))

    rank = train.get_context().get_world_rank()
    is_main = rank == 0

    def log(*a):
        if is_main:
            print(*a, flush=True)

    log(f"[setup] world_size={train.get_context().get_world_size()}")

    # ---- Dataset (staged locally by demo_1; no hub access) ----
    parquet = sorted(glob.glob(os.path.join(DATASET_PATH, "**", "*.parquet"), recursive=True))
    if parquet:
        dataset = load_dataset("parquet", data_files=parquet, split="train")
    else:
        dataset = load_dataset(DATASET_PATH, split="train")

    def format_instruction(example):
        instr = example.get("instruction", "")
        if example.get("input"):
            instr += f"\n{example['input']}"
        text = (
            f"<|im_start|>user\n{instr}<|im_end|>\n"
            f"<|im_start|>assistant\n{example.get('output', '')}<|im_end|>"
        )
        return {"text": text}

    dataset = dataset.map(format_instruction, remove_columns=list(dataset.features))
    split = dataset.train_test_split(test_size=EVAL_SAMPLES, seed=42)
    train_ds, eval_ds = split["train"], split["test"]
    log(f"[data] train={len(train_ds)} eval={len(eval_ds)} from {DATASET_PATH}")

    # ---- Base model + tokenizer (bf16, no quantization) ----
    log(f"[model] loading {MODEL_PATH}")
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_PATH, torch_dtype=torch.bfloat16, trust_remote_code=True,
    )
    model.config.use_cache = False  # required with gradient checkpointing

    tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    lora_config = LoraConfig(
        r=LORA_RANK,
        lora_alpha=LORA_RANK * 2,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"],
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
    )

    training_args = TrainingArguments(
        output_dir="/tmp/sft-checkpoints",
        max_steps=MAX_STEPS,
        per_device_train_batch_size=BATCH_SIZE,
        per_device_eval_batch_size=BATCH_SIZE,
        gradient_accumulation_steps=1,
        learning_rate=LEARNING_RATE,
        warmup_ratio=0.03,
        lr_scheduler_type="cosine",
        logging_steps=10,
        eval_strategy="steps",
        eval_steps=MAX_STEPS // 2,
        save_strategy="no",
        bf16=True,
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        ddp_find_unused_parameters=False,
        disable_tqdm=True,
        report_to="none",
    )

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_ds,
        eval_dataset=eval_ds,
        peft_config=lora_config,
        max_seq_length=MAX_SEQ_LENGTH,
        tokenizer=tokenizer,
        dataset_text_field="text",
        packing=True,
    )
    # Bridge HF Trainer -> Ray Train (metric reporting); prepare_trainer validates the
    # Trainer runs correctly under Ray Train's already-established process group.
    trainer.add_callback(RayTrainReportCallback())
    trainer = prepare_trainer(trainer)
    if is_main:
        trainer.model.print_trainable_parameters()

    log("[train] starting...")
    train_result = trainer.train()

    eval_metrics = trainer.evaluate()
    eval_loss = eval_metrics["eval_loss"]
    log(f"[result] train_loss={train_result.metrics.get('train_loss'):.4f} "
        f"eval_loss={eval_loss:.4f} perplexity={math.exp(eval_loss):.2f} "
        f"runtime={train_result.metrics.get('train_runtime'):.1f}s")

    # Write the adapter (+ tokenizer) to the results PVC from the primary worker.
    if is_main:
        log(f"[save] writing LoRA adapter to {OUTPUT_DIR}")
        trainer.save_model(OUTPUT_DIR)
        tokenizer.save_pretrained(OUTPUT_DIR)
        print("=== Fine-tuning complete. Adapter written to", OUTPUT_DIR, "===", flush=True)


def main():
    ray.init()  # connects to the KubeRay cluster this RayJob runs on
    num_workers = int(os.environ.get("NUM_WORKERS", "4"))
    scaling_config = ScalingConfig(
        num_workers=num_workers,
        use_gpu=True,
        resources_per_worker={"GPU": 1, "CPU": 4},
    )
    # storage_path (Ray Train's experiment dir) must be reachable from driver + workers ->
    # the shared results PVC. Kept under the per-framework kuberay folder so it sits next to
    # the saved adapter and away from demo_3's /mnt/results/kubeflow output.
    run_config = RunConfig(
        name="qwen-sft-ray",
        storage_path=os.environ.get("RAY_STORAGE", "/mnt/results/kuberay/ray-runs"),
    )
    trainer = TorchTrainer(
        train_func,
        scaling_config=scaling_config,
        run_config=run_config,
    )
    result = trainer.fit()
    print(f"[driver] final metrics: {result.metrics}", flush=True)
    ray.shutdown()


if __name__ == "__main__":
    main()
