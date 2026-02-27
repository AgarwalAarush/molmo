#!/bin/bash
#SBATCH --job-name=molmo-eval
#SBATCH --output=molmo-eval-%j.out
#SBATCH --error=molmo-eval-%j.err
#SBATCH --partition=general
#SBATCH --time=6:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=32
#SBATCH --mem=128G

# Optional: wait for train job to finish first
# SBATCH --dependency=afterok:JOBID

set -e

# CHECKPOINT: path to trained model (directory with config.yaml and model.pt or step*-unsharded)
CHECKPOINT="${1:-/data/user_data/${USER}/molmo/checkpoints/captioner}"

echo "=== Job started at $(date) ==="
echo "Running on node: $(hostname)"
echo "Checkpoint: $CHECKPOINT"

# 1. Activate conda env
source $(conda info --base)/etc/profile.d/conda.sh
conda activate molmo

# 2. Environment variables — match download_molmo.sh paths
export MOLMO_DATA_DIR=/data/hf_cache/molmo
export HF_HOME=/data/user_data/${USER}/.hf_cache
export HF_HUB_CACHE=/data/hf_cache/hub
export HF_DATASETS_CACHE=/data/hf_cache/datasets
export HF_DATASETS_OFFLINE=1

# 3. Go to molmo repo (SLURM_SUBMIT_DIR when sbatch; else script dir)
cd "${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"

# 4. Eval on tasks (low-res = quick, high-res = full 11-benchmark)
# For high-res add: --high_res --fsdp --device_batch_size=2
torchrun --nproc-per-node=8 launch_scripts/eval_downstream.py "$CHECKPOINT" low-res \
  --save_to_checkpoint_dir

echo "=== Job finished at $(date) ==="
