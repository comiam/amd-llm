#!/usr/bin/env bash
#
# STEP‑1.  Настройка Alveo U250 под Vitis‑AI 2.5
#          (XRT + runtime + overlay DPUCADF8H)
#
# Официальный мастер‑скрипт:
#   https://raw.githubusercontent.com/Xilinx/Vitis-AI/v2.5/setup/alveo/install.sh
#

set -euo pipefail
CFG="configs/config.yaml"
BASE="$(yq '.paths.base_dir' "$CFG")"
VAI_HOME="$BASE/Vitis-AI-2.5"

if ! command -v xbutil &>/dev/null; then
  git clone --depth 1 --branch v2.5 https://github.com/Xilinx/Vitis-AI.git "$VAI_HOME"
  cd "$VAI_HOME/setup/alveo"
  sudo ./install.sh
else
  echo "[02] XRT already installed – skipping."
fi

# Проверяем наличие overlay‑бинарей DPUCADF8H
if ! ls /opt/xilinx/overlaybins/DPUCADF8H/*/dpu.xclbin &>/dev/null; then
  echo "[ERR] Overlay DPUCADF8H not found."
  exit 1
fi

# -- Автоматически определяем PCIe BDF карты U250 -----------------------
BDF=$(lspci -d 10ee: -D | awk '/u250/i {print $1; exit}')
[[ -z $BDF ]] && BDF="0000:03:00.0"
echo "xbmgmt partition ... --card $BDF"


echo -e "\n\e[33m[!] Reboot is required.\n"\
        "After reboot program base‑shell once:\n\n"\
        "sudo /opt/xilinx/xrt/bin/xbmgmt partition --program \\\n"\
        "     --name xilinx_u250_gen3x16_xdma_shell_3_1 --card $BDF\n\e[0m"
