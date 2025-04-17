#!/usr/bin/env bash
#
# STEP‑0  -  базовая подготовка Ubuntu 20.04 LTS
#
# Источники:
#   • Vitis‑AI 2.5 README (https://github.com/Xilinx/Vitis-AI/blob/v2.5/setup/alveo/README.md)
#

set -euo pipefail
BASE="$HOME/Apps/amd-llm";  mkdir -p "$BASE"

sudo apt update && sudo apt -y upgrade
sudo apt install -y build-essential git wget jq yq cmake dkms pciutils \
                     python3-venv python3-pip

# Python venv
python3 -m venv "$BASE/venv"
source "$BASE/venv/bin/activate"
pip install -U pip wheel
pip install torch==2.1.2 transformers==4.41.1 tvm==0.16.0 \
            fastapi uvicorn pydantic pyyaml requests tqdm \
            onnx onnxruntime

echo -e "\e[32m[01] System packages & venv installed.\e[0m"
