#!/usr/bin/env bash
# Environment activator for Alveo U250  +  Vitis‑AI 2.5

source /opt/xilinx/xrt/setup.sh
BASE="$HOME/Apps/amd-llm"
source "$BASE/venv/bin/activate"

VAI_HOME="$BASE/Vitis-AI-2.5"
export PYTHONPATH="$VAI_HOME/tools/Vitis-AI-Library/python:$PYTHONPATH"
export LD_LIBRARY_PATH="/opt/xilinx/overlaybins/DPUCADF8H:$LD_LIBRARY_PATH"

echo "[env] Environment ready."
