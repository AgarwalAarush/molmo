# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Molmo (Multimodal Open Language Model) is AI2's multimodal VLM training and evaluation codebase, built on top of OLMo. The Python package is named `ai2-molmo` but the source lives in the `olmo/` directory. Requires Python 3.10+.

## Common Commands

### Installation
```bash
pip install -e .[all]
# For MoE (MolmoE-1B): pip install git+https://github.com/Muennighoff/megablocks.git@olmoe
```

### Testing
```bash
pytest tests/                          # all tests
pytest tests/beam_search_test.py -v    # single test file
```

### Code Quality
```bash
ruff check olmo/                       # linting
black --check olmo/                    # format check
isort --check olmo/                    # import order check
mypy olmo/                             # type checking (>=1.0,<1.4)
```

### Training (torchrun)
```bash
# Debug (1 GPU)
torchrun --nproc-per-node=1 launch_scripts/train_captioner.py debug --save_folder=/path/to/save

# Full (8 GPUs)
torchrun --nproc-per-node=8 launch_scripts/train_captioner.py qwen2_7b --save_folder=/path/to/save

# Multitask fine-tuning
torchrun --nproc-per-node=8 launch_scripts/train_multitask_model.py 3.2-synthetic /path/to/checkpoint --save_folder=/path/to/save
```

### Evaluation
```bash
torchrun --nproc-per-node=8 launch_scripts/eval_downstream.py Molmo-7B-D-0924 text_vqa --save_to_checkpoint_dir
```

### Data
```bash
python3 scripts/download_data.py all --n_proc 12       # download all datasets
python3 scripts/download_data.py chart_qa --n_proc 12   # specific dataset
python3 scripts/dataset_visualize.py chart_qa /path/to/viz/dir
```

## Architecture

### Source layout (`olmo/` package)
- **`model.py`**: Core `Molmo` class — multimodal transformer combining vision encoder with LLM. Supports RoPE, GQA, activation checkpointing, FSDP, and MoE (via megablocks).
- **`image_vit.py`**: Vision transformer implementations — `VisionTransformer` (CLIP), `SiglipVisionTransformer`, `DinoVisionTransformer`. Pluggable via config.
- **`config.py`**: All configuration as dataclasses (`ModelConfig`, `VisionBackboneConfig`, `TrainConfig`, `DataConfig`, `OptimizerConfig`, `SchedulerConfig`, `FSDPConfig`). Uses OmegaConf for YAML loading/overrides.
- **`train.py`**: `Trainer` class — training loop with FSDP, gradient accumulation, W&B integration, checkpoint management.
- **`checkpoint.py`**: Distributed checkpoint save/load, FSDP sharding, cloud storage (S3/GCS).
- **`optim.py`**: Custom `Optimizer` with gradient clipping. Schedulers: `CosWithWarmup`, `LinearWithWarmup`, `InvSqrtWithWarmup`, `MaxScheduler`.
- **`beam_search.py`**: Beam search decoding for generation.
- **`tokenizer.py`**: Tokenizer wrapper around HuggingFace tokenizers.
- **`hf_molmo.py`**: Load models from HuggingFace format.

### Data pipeline (`olmo/data/`)
- **`dataset.py`**: Base dataset classes and abstract interfaces.
- **`academic_datasets.py`**: 20+ VQA datasets (ChartQA, TextVQA, DocQA, AI2D, MMMU, etc.).
- **`pixmo_datasets.py`**: PixMo dataset collection (Cap, AskModelAnything, CapQA, Points, Docs, Clocks, Count).
- **`collator.py`**: `MMCollator` for multimodal batch assembly.
- **`model_preprocessor.py`**: Image loading, resizing, padding, crop strategies.
- **`iterable_dataset_mixture.py`**: Weighted mixture-of-datasets sampling.

### Evaluation (`olmo/eval/`)
- **`evaluators.py`**: VQA metrics (VQA score, ANLS, relaxed correctness, MC accuracy, pointing, counting).
- **`inf_evaluator.py`**: Inference-time evaluation with generation.
- **`loss_evaluator.py`**: Loss-based evaluation during training.

### Entry points
- **`scripts/train.py`**: Main training script (used with torchrun).
- **`launch_scripts/train_captioner.py`**: Pre-training launch script with preset configs.
- **`launch_scripts/train_multitask_model.py`**: Multitask fine-tuning.
- **`launch_scripts/eval_downstream.py`**: Benchmark evaluation.
- **`launch_scripts/utils.py`**: Shared config builders and evaluator definitions.
- **`scripts/convert_hf_to_molmo.py`**: Convert HuggingFace checkpoints to Molmo format.
- **`scripts/unshard.py`**: Unshard FSDP checkpoints for inference.

## Key Patterns

- **Configuration-driven**: All architecture, training, and data settings are dataclass configs in `config.py`, composed via OmegaConf. Launch scripts build configs programmatically and pass them to the trainer.
- **FSDP-first distributed training**: Model parallelism via PyTorch FSDP with sharded checkpoints. Always launched with `torchrun`.
- **Pluggable vision backbones**: Vision encoder is selected via `VisionBackboneConfig.image_model_type` ("openai", "siglip", "dino") and swapped without changing the LLM.
- **Dataset mixtures**: Training data is composed from multiple datasets with configurable sampling weights via `iterable_dataset_mixture.py`.

## Environment Variables
```bash
MOLMO_DATA_DIR=/data/molmo           # root data directory
HF_HOME=/data/molmo/huggingface      # HuggingFace cache
HF_DATASETS_OFFLINE=1                # required for multi-node training
```
