#!/usr/bin/env bash
#
# STEP‑2 -  download model, then run host+Docker conversion -> TVM bundle
#

set -euo pipefail
CFG="configs/config.yaml"
BDIR="$(yq '.paths.base_dir' "$CFG")"
MDIR="$(yq '.paths.models_dir' "$CFG")/$(yq '.model.name' "$CFG")"
mkdir -p "$MDIR"

source "$BDIR/venv/bin/activate"
python utils/download_model.py --config "$CFG"

python utils/convert_model_for_alveo.py \
  --model-dir "$MDIR" \
  --xclbin "$(yq '.alveo.xclbin' "$CFG")" \
  --precision "$(yq '.model.precision' "$CFG")"
