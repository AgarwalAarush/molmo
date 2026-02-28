#!/bin/bash
#SBATCH --job-name=molmo-train
#SBATCH --output=molmo-train-%j.out
#SBATCH --error=molmo-train-%j.err
#SBATCH --partition=general
#SBATCH --time=2-00:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=32
#SBATCH --mem=128G

# Optional: wait for download job to finish first
# SBATCH --dependency=afterok:JOBID

set -e

echo "=== Job started at $(date) ==="
echo "Running on node: $(hostname)"

# 1. Activate conda env
source $(conda info --base)/etc/profile.d/conda.sh
conda activate molmo

# 2. Environment variables — match download_molmo.sh paths
export MOLMO_DATA_DIR=/data/hf_cache/molmo
export HF_HOME=/data/user_data/${USER}/.hf_cache
export HF_HUB_CACHE=/data/hf_cache/hub
export HF_DATASETS_CACHE=/data/hf_cache/datasets
export HF_DATASETS_OFFLINE=1
export PYTHONPATH="$(pwd):${PYTHONPATH}"

# 3. Go to molmo repo (SLURM_SUBMIT_DIR when sbatch; else script dir)
cd "${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"

# 4. Train (debug = 1 GPU quick test, qwen2_7b = full 8 GPU)
# For debug: change to --gres=gpu:1 and use debug
torchrun --nproc-per-node=8 launch_scripts/train_captioner.py qwen2_7b \
  --save_folder=/data/user_data/${USER}/molmo/checkpoints/captioner \
  --wandb=null \
  --save_overwrite

echo "=== Job finished at $(date) ==="
