#!/bin/bash
#SBATCH --job-name=molmo-transfer-dl
#SBATCH --output=molmo-transfer-dl-%j.out
#SBATCH --error=molmo-transfer-dl-%j.err
#SBATCH --partition=cpu
#SBATCH --time=2-00:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G

# Transfer partial Molmo data from user_data to shared hf_cache, then resume download.
# Must run on compute node (sbatch) because /data/user_data is only available there.

set -e

echo "=== Job started at $(date) ==="
echo "Running on node: $(hostname)"

# 1. Activate conda env
source $(conda info --base)/etc/profile.d/conda.sh
conda activate molmo

# 2. Paths
USER_DATA_MOLMO="/data/user_data/${USER}/molmo"
HF_CACHE_MOLMO="/data/hf_cache/molmo"
SRC_TORCH_DATASETS="${USER_DATA_MOLMO}/torch_datasets"
DST_TORCH_DATASETS="${HF_CACHE_MOLMO}/torch_datasets"

# 3. Environment variables — use shared HF cache and hf_cache for Molmo data
export MOLMO_DATA_DIR="${HF_CACHE_MOLMO}"
export HF_HOME="/data/user_data/${USER}/.hf_cache"
export HF_HUB_CACHE="/data/hf_cache/hub"
export HF_DATASETS_CACHE="/data/hf_cache/datasets"

# 4. Create destination and transfer partial data (if source exists)
mkdir -p "${HF_CACHE_MOLMO}"
mkdir -p "${HF_HOME}"

if [[ -d "${SRC_TORCH_DATASETS}" ]]; then
    echo "=== Transferring partial data from user_data to hf_cache ==="
    echo "Source: ${SRC_TORCH_DATASETS}"
    echo "Dest:   ${DST_TORCH_DATASETS}"
    mv "${SRC_TORCH_DATASETS}" "${DST_TORCH_DATASETS}"
    echo "Transfer complete."
else
    echo "No existing torch_datasets at ${SRC_TORCH_DATASETS} — starting fresh."
    mkdir -p "${DST_TORCH_DATASETS}"
fi

# 5. Go to molmo repo
cd "$(dirname "$0")"

# 6. Download datasets (resumes if partial data was transferred)
echo "=== Downloading PixMo (training data) ==="
python3 scripts/download_data.py pixmo --n_procs 16

echo "=== Downloading ChartQA (eval data) ==="
python3 scripts/download_data.py chart_qa --n_procs 16

# 7. Convert pretrained models
echo "=== Converting Qwen2-7B ==="
python3 scripts/convert_hf_to_molmo.py qwen2_7b

echo "=== Converting OpenAI CLIP ==="
python3 scripts/convert_hf_to_molmo.py openai

echo "=== Job finished at $(date) ==="