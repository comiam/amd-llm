#!/usr/bin/env bash
#
# STEP‑0  -  базовая подготовка Ubuntu 20.04 LTS
#
# Источники:
#   • Vitis‑AI 2.5 README (https://github.com/Xilinx/Vitis-AI/blob/v2.5/setup/alveo/README.md)
#

set -euo pipefail
CFG="configs/config.yaml"

sudo apt update && sudo apt -y upgrade
sudo apt install -y build-essential git wget jq cmake dkms pciutils \
    python3-venv python3-pip
sudo snap install yq

BASE="$(yq '.paths.base_dir' "$CFG")"
mkdir -p "$BASE"

# Python venv
pip install --upgrade pip
python3.11 -m venv "$BASE/venv"
source "$BASE/venv/bin/activate"
pip install -U pip wheel
pip install torch==2.6.0 transformers==4.51.3 apache-tvm==0.14.dev273 \
    fastapi uvicorn pydantic pyyaml requests tqdm \
    onnx onnxruntime

echo -e "\e[32m[01] System packages & venv installed.\e[0m"
