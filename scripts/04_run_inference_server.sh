#!/usr/bin/env bash
set -euo pipefail
CFG="configs/config.yaml"
BASE="$(yq '.paths.base_dir' "$CFG")"

source "$BASE/setup_env.sh"
uvicorn utils.inference_server:create_app \
        --factory --host "$(yq '.server.host' $CFG)" --port "$(yq '.server.port' $CFG)" \
        --log-level info --config "$CFG"
