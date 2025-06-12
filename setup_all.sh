#!/usr/bin/env bash
#
# setup_all.sh – запускайте СТРОГО под sudo; скрипт идемпотентный.
#

set -euo pipefail
CFG="configs/config.yaml"
BASE="$(yq '.paths.base_dir' "$CFG")"
LOG="logs/setup_all.log"
mkdir -p logs
exec > >(tee -a "$LOG") 2>&1

overlay_ready() { ls /opt/xilinx/overlaybins/DPUCADF8H/*/dpu.xclbin &>/dev/null; }
conda_env_ready() { [[ -d "$BASE/env" ]]; }
model_ready() { [[ -f "$(yq '.paths.models_dir' $CFG)/$(yq '.model.name' $CFG)/alveo/model_alveo.so" ]]; }
server_running() { pgrep -f "uvicorn.*inference_server" &>/dev/null; }

echo -e "\n=== AMD Alveo U250 LLM bootstrap ==="

# STEP‑0
if ! conda_env_ready; then
  ./scripts/01_prepare_system.sh
  echo "Reboot required, then rerun setup_all.sh"
  exit
fi

# STEP‑1
./scripts/02_prepare_alveo_for_llm.sh

# STEP‑2
if ! model_ready; then
  ./scripts/03_prepare_qwen_model.sh
fi

# STEP‑3
if ! server_running; then
  ./scripts/04_run_inference_server.sh &
  echo "[run] Inference server started."
fi

echo -e "\e[32mAll done ->  http://$(yq '.server.host' $CFG):$(yq '.server.port' $CFG)\e[0m"
