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

# 2. Environment variables
export MOLMO_DATA_DIR=/data/user_data/aarusha/molmo
export HF_HOME=/data/user_data/aarusha/.hf_cache
export HF_DATASETS_OFFLINE=1

# 3. Go to molmo repo
cd "$(dirname "$0")"

# 4. Train (debug = 1 GPU quick test, qwen2_7b = full 8 GPU)
# For debug: change to --gres=gpu:1 and use debug
torchrun --nproc-per-node=8 launch_scripts/train_captioner.py qwen2_7b \
  --save_folder=/data/user_data/aarusha/molmo/checkpoints/captioner \
  --wandb=null

echo "=== Job finished at $(date) ==="
