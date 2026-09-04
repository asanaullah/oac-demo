# Assisted by Claude Opus
# LoRA fine-tuning of a causal LM with the HuggingFace SFTTrainer, launched one process
# per GPU by `torchrun` (DistributedDataParallel). Everything is read from / written to
# the demo PVCs — the base model and dataset are staged locally by demo_1, so no HF hub
# access is needed. Paths and hyper-parameters come from env vars set by the manifest.
import glob
import math
import os

import torch
from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments
from peft import LoraConfig
from trl import SFTTrainer

MODEL_PATH = os.environ["MODEL_PATH"]
DATASET_PATH = os.environ["DATASET_PATH"]
OUTPUT_DIR = os.environ["OUTPUT_DIR"]
MAX_STEPS = int(os.environ.get("MAX_STEPS", "60"))
EVAL_SAMPLES = int(os.environ.get("EVAL_SAMPLES", "200"))
LEARNING_RATE = float(os.environ.get("LEARNING_RATE", "2e-4"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "8"))
LORA_RANK = int(os.environ.get("LORA_RANK", "16"))
MAX_SEQ_LENGTH = int(os.environ.get("MAX_SEQ_LENGTH", "2048"))

# torchrun sets LOCAL_RANK/WORLD_SIZE; keep our prints on the primary rank only.
LOCAL_RANK = int(os.environ.get("LOCAL_RANK", "0"))
is_main = LOCAL_RANK == 0


def log(*a):
    if is_main:
        print(*a, flush=True)


if is_main:
    n = torch.cuda.device_count()
    gpus = ", ".join(torch.cuda.get_device_name(i) for i in range(n))
    log(f"[setup] world_size={os.environ.get('WORLD_SIZE')} gpus={n} ({gpus})")

# ---- Dataset (staged locally by demo_1; no hub access) ----
parquet = sorted(glob.glob(os.path.join(DATASET_PATH, "**", "*.parquet"), recursive=True))
if parquet:
    dataset = load_dataset("parquet", data_files=parquet, split="train")
else:
    dataset = load_dataset(DATASET_PATH, split="train")


# Alpaca-style records -> a single chat-formatted "text" field (Qwen ChatML markers).
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
# Hold out a small split so we can report a real metric (eval loss / perplexity).
split = dataset.train_test_split(test_size=EVAL_SAMPLES, seed=42)
train_ds, eval_ds = split["train"], split["test"]
log(f"[data] train={len(train_ds)} eval={len(eval_ds)} from {DATASET_PATH}")

# ---- Base model + tokenizer (bf16, no quantization — H100s have the memory) ----
log(f"[model] loading {MODEL_PATH}")
model = AutoModelForCausalLM.from_pretrained(
    MODEL_PATH,
    torch_dtype=torch.bfloat16,
    trust_remote_code=True,
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
    logging_steps=10,          # a train-loss line every 10 steps: enough to see progress
    eval_strategy="steps",
    eval_steps=MAX_STEPS // 2,  # a mid-run and (via final evaluate) an end metric
    save_strategy="no",
    bf16=True,
    gradient_checkpointing=True,
    gradient_checkpointing_kwargs={"use_reentrant": False},
    ddp_find_unused_parameters=False,
    disable_tqdm=True,         # clean per-step log lines instead of a progress bar
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
if is_main:
    trainer.model.print_trainable_parameters()

log("[train] starting...")
train_result = trainer.train()

# ---- Report a real metric: eval loss on the held-out split (+ perplexity) ----
eval_metrics = trainer.evaluate()
eval_loss = eval_metrics["eval_loss"]
log(f"[result] train_loss={train_result.metrics.get('train_loss'):.4f} "
    f"eval_loss={eval_loss:.4f} perplexity={math.exp(eval_loss):.2f} "
    f"runtime={train_result.metrics.get('train_runtime'):.1f}s")

# save_model is rank-aware; write the adapter (+ tokenizer) to the results PVC.
log(f"[save] writing LoRA adapter to {OUTPUT_DIR}")
trainer.save_model(OUTPUT_DIR)
if trainer.is_world_process_zero():
    tokenizer.save_pretrained(OUTPUT_DIR)
    print("=== Fine-tuning complete. Adapter written to", OUTPUT_DIR, "===", flush=True)
