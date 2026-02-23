#!/bin/bash
#SBATCH --job-name=molmo-download
#SBATCH --output=molmo-download-%j.out
#SBATCH --error=molmo-download-%j.err
#SBATCH --partition=cpu
#SBATCH --time=2-00:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G

set -e

echo "=== Job started at $(date) ==="
echo "Running on node: $(hostname)"

# 1. Activate conda env
source $(conda info --base)/etc/profile.d/conda.sh
conda activate molmo

# 2. Environment variables (compute node has /data/user_data)
export MOLMO_DATA_DIR=/data/user_data/aarusha/molmo
export HF_HOME=/data/user_data/aarusha/.hf_cache

# 3. Create directories (in case they don't exist)
mkdir -p "$MOLMO_DATA_DIR"
mkdir -p "$HF_HOME"

# 4. Go to molmo repo (script is in repo root)
cd "$(dirname "$0")"

# 5. Download datasets
# n_procs: More = faster, but README warns "increases risk of getting rate-limited"
# 16 is a balance; if you hit 429 errors, reduce to 8-12
echo "=== Downloading PixMo (training data) ==="
python3 scripts/download_data.py pixmo --n_procs 16

echo "=== Downloading ChartQA (eval data) ==="
python3 scripts/download_data.py chart_qa --n_procs 16

# 6. Convert pretrained models for full training later
echo "=== Converting Qwen2-7B ==="
python3 scripts/convert_hf_to_molmo.py qwen2_7b

echo "=== Converting OpenAI CLIP ==="
python3 scripts/convert_hf_to_molmo.py openai

echo "=== Job finished at $(date) ==="
