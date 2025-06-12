#!/usr/bin/env bash
################################################################################
# STEP‑1.  Настройка Alveo U250 под Vitis‑AI 2.5
#
# Документация (обязательно к прочтению):
#   * UG1301 Environment Setup / Confirm Firmware Installation / Card Validation
#     https://docs.amd.com/r/en-US/ug1301-getting-started-guide-alveo-accelerator-cards
#   * AMD AR #75975  (динамические партиции / base‑shell для U250)
#     https://adaptivesupport.amd.com/s/article/75975?language=en_US
#   * Vitis‑AI 2.5 README
#     https://github.com/Xilinx/Vitis-AI/blob/v2.5/setup/alveo/README.md
#     Alveo Card Debug Guide
#   * https://xilinx.github.io/Alveo-Cards/master/debugging/build/html/docs/common-steps.html#programming-dfx-2rp-shell-partitions
#     UG1354 Vitis AI library User Guide
#     https://docs.amd.com/r/2.5-English/ug1354-xilinx-ai-sdk/For-Cloud-Alveo-U200/U250-Cards?tocId=Cxh43e4tdCxrMteHDZOxFA
#     UG1414 Vitis AI 2.5 User Guide
#     https://docs.amd.com/r/2.5-English/ug1414-vitis-ai/Alveo-U200/U250-Card-DPUCADF8H
#
# Скрипт выполняет:
#   1) Установку XRT / runtime через Vitis‑AI v2.5
#   2) Проверку overlay‑бинария DPUCADF8H
#   3) Определение PCIe‑BDF карты       (lspci)
#   4) Проверку актуального base‑shell  (xbmgmt examine)
#   5) При необходимости прошивку base‑shell  (xbmgmt partition --program)
#   6) Валидацию карты      (xbutil validate - Basic & Platform tests)
################################################################################
set -euo pipefail

get_xilinx_url() {
  echo "https://www.xilinx.com/bin/public/openDownload?filename=$1"
}

download_error() {
  echo -e "\e[31m[ERR] Failed to automatically download deployment packages.\e[0m"
  echo "      Please download manually from the 'Alveo U250 Package Downloads' portal."
  exit 1
}

download_files() {
  local tmp_dir="$1"
  local files=("${@:2}")

  local dl_ok=
  for f in "${files[@]}"; do
    local url
    url="$(get_xilinx_url "$f")"
    echo "  ↳ wget -q --show-progress $f"
    if wget -q --show-progress -O "$tmp_dir/$f" "$url"; then
      dl_ok=1
      break
    fi
  done
  echo "$dl_ok"
}

# Установка XRT (Xilinx Runtime) для U250
#   * https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u250.html#alveotabs-item-vitis-tab
install_xrt() {
  local tmp_dir="$1"
  local xrt_files=("${@:2}")

  if [[ ! -d "/opt/xilinx/xrt" ]]; then
    echo "XRT not found -> installing from direct URL..."

    if [[ -z "$(download_files "$tmp_dir" "${xrt_files[@]}")" ]]; then
      download_error
    fi

    sudo apt install -y "$tmp_dir/xrt_2022*"

    echo "XRT package installed successfully."
  else
    echo "XRT already installed - skipping step."
  fi
}

# Загрузка и установка пакетов платформы развертывания для U250 от Xilinx
#   * https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u250.html#alveotabs-item-vitis-tab
download_deployment_target_packages() {
  local tmp_dir="$1"
  local deploy_files=("${@:2}")

  if dpkg -l | grep -q "xilinx-u250.*"; then
    echo "Deployment Target Platform packages are present."
  else
    echo "Deployment Target Platform packages are missing - attempting to download automatically…"

    local downloaded_file=""
    if [[ -z "$(download_files "$tmp_dir" "${deploy_files[@]}")" ]]; then
      download_error
    fi

    # Найдем загруженный файл (должен быть только один .tar.gz файл)
    downloaded_file=$(find "$tmp_dir" -name "xilinx-u250-*.tar.gz" -type f | head -n1)

    if [[ -z "$downloaded_file" ]]; then
      echo -e "\e[31m[ERR] Downloaded file not found in $tmp_dir\e[0m"
      exit 1
    fi

    echo "Extracting $(basename "$downloaded_file") ..."
    tar -xf "$downloaded_file" -C "$tmp_dir"

    # UG1301 порядок установки пакетов:
    echo "Installing .deb (SC -> CMC -> Base -> Shell)"
    sudo apt install -y "$tmp_dir"/xilinx-sc-fw-*.deb
    sudo apt install -y "$tmp_dir"/xilinx-cmc-*.deb
    sudo apt install -y "$tmp_dir"/xilinx-u250-gen3x16-base*.deb
    sudo apt install -y "$tmp_dir"/xilinx-u250-gen3x16-xdma-validate*.deb
    sudo apt install -y "$tmp_dir"/xilinx-u250-gen3x16-xdma-shell*.deb
  fi
}

load_kernel_modules() {
  for m in xclmgmt xocl; do
    if ! lsmod | grep -q "$m"; then
      echo "Loading kernel module $m ..."
      if ! sudo modprobe "$m"; then
        echo -e "\033[0;31m[ERR] Failed to load module $m.\033[0m"
      fi
    fi
  done
}

# Поиск и корректировка найденного PCIe‑BDF карты U250 (UG1301)
find_u250_bdf() {
  local bdf
  bdf=$(lspci -d 10ee: -D | awk '{print $1; exit}')
  if [[ -z "$bdf" ]]; then
    echo -e "\033[0;31m[ERR] U250 card not found in the system!\033[0m"
    exit 1
  fi

  # Проверяем, что BDF начинается с 0000:
  if [[ "$bdf" != 0000:* ]]; then
    bdf="0000:$bdf"
  fi
  echo "$bdf"
}

# Получение текущего имени оболочки карты U250
get_current_shell() {
  local bdf="$1"
  local cur_shell

  cur_shell=$(xbmgmt examine --device "$bdf" --report platform | grep -F "[$bdf]" | sed -e 's/.*: //')
  [[ -z "$cur_shell" ]] && cur_shell="unknown"

  echo "$cur_shell"
}

# Прошивка разделов (75975, UG1301)
flash_partitions() {
  local cur_shell="$1"
  local flag_value="$2"
  local bdf="$3"
  local target_shell="$4"
  local target_shell_dir="$5"
  local base_program_status_flag="$6"

  # Первый шаг - прошивка базового раздела
  if [[ "$cur_shell" != "$target_shell" && "$flag_value" != "SC" ]]; then
    echo "Flashing base partition -> $target_shell"
    sudo /opt/xilinx/xrt/bin/xbmgmt program --base --device "$bdf" --force
    echo -e "\e[33m[!] Cold reboot REQUIRED. Rerun script afterwards.\e[0m"
    echo "SC" >"$base_program_status_flag"
  fi

  # Второй шаг - прошивка раздела Satellite Control (SC)
  if [[ "$flag_value" == "SC" ]]; then
    echo "Flashing SC partition"
    sudo /opt/xilinx/xrt/bin/xbmgmt program --base --device "$bdf" --force
    echo -e "\e[33m[!] Warm reboot REQUIRED. Rerun script afterwards.\e[0m"
    echo "SCHELL" >"$base_program_status_flag"
  fi

  # Третий шаг - прошивка раздела оболочки (необходимо для платформ DFX-2RP с двухэтапной загрузкой)
  if [[ "$flag_value" == "SCHELL" ]]; then
    echo "Flashing shell partition"
    sudo /opt/xilinx/xrt/bin/xbmgmt program --shell "$target_shell_dir" --device "$bdf" --force
    echo -e "\e[33m[!] U250 flashed successfully. \e[0m"
    echo "Notice that after cold and warm reboot shell flashing is repeatly required."
  fi
}

# Установка среды выполнения Vitis‑AI
install_vitis_ai_runtime() {
  local vai_home="$1"
  local overlay_ip="$2"
  if ! ls /opt/xilinx/overlaybins/"$overlay_ip"/*/dpu.xclbin &>/dev/null; then
    echo "Vitis‑AI not found, attempting to install from repository..."

    if [[ ! -d "$vai_home" ]]; then
      git clone --depth 1 --branch v2.5 https://github.com/Xilinx/Vitis-AI.git "$vai_home"
    else
      echo "Vitis-AI repository already exists - skipping step."
    fi

    export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}
    export PYTHONPATH=${PYTHONPATH:-/usr/bin/python3.11}

    cd "$vai_home/setup/alveo/scripts"
    source ./install_u250_xclbins.sh
  else
    echo "Vitis-AI overlay already installed - skipping step."
  fi
}

# Проверка готовности устройства (Device Ready)
check_device_ready() {
  local bdf="$1"
  local status

  echo "Checking if device $bdf is ready..."

  # Выполняем команду xbmgmt examine
  local output
  output=$(sudo /opt/xilinx/xrt/bin/xbmgmt examine)

  # Ищем строку с нашим BDF и извлекаем значение Device Ready (последняя колонка)
  status=$(echo "$output" | grep -F "[$bdf]" | grep -oE 'Yes|No')

  if [[ "$status" == "Yes" ]]; then
    echo "Device $bdf is ready (Device Ready: Yes)"
    return 0
  else
    echo -e "\e[33m[WARN] Device $bdf is not ready (Device Ready: $status)\e[0m"
    return 1
  fi
}

main() {
  CFG="configs/config.yaml"

  # Проверка наличия yq
  if ! command -v yq &>/dev/null; then
    echo -e "\e[31m[ERR] Утилита 'yq' не найдена. Установите её: pip install yq\e[0m"
    exit 1
  fi

  BASE_DIR="$(yq '.paths.base_dir' "$CFG")"
  VAI_HOME="$BASE_DIR/Vitis-AI-2.5"

  TARGET_SHELL="xilinx_u250_gen3x16_base_4" #75975
  TARGET_SHELL_DIR="/lib/firmware/xilinx/12c8fafb0632499db1c0c6676271b8a6/partition.xsabin"
  OVERLAY_IP="DPUCADF8H" # U250 IP (Github: Vitis-AI)

  # Определение временной директории TMP для всех операций
  TMP=/tmp/u250_deploy
  mkdir -p "$TMP"
  BASE_PROGRAM_STATUS_FLAG="$TMP/base_program_flash_status"

  # =============================================================
  #  Список "известных" архивов (публичный openDownload):
  #  Источник = https://www.amd.com/en/support/downloads/alveo-previous-downloads.html/accelerators/alveo/u250.html#alveotabs-item-vitis-tab
  #  Резервный вариант = 2022.1
  # =============================================================
  XRT_FILES=(
    xrt_202220.2.14.354_20.04-amd64-xrt.deb
    xrt_202210.2.13.466_20.04-amd64-xrt.deb
  )

  DEPLOY_FILES=(
    xilinx-u250-gen3x16-xdma_2022.2_2022_1015_0317-all.deb.tar.gz
    xilinx-u250-gen3x16-xdma_2022.1_2022_0415_2123-all.deb.tar.gz
  )

  echo -e "\n\033[1;34m=== Alveo U250 provisioning (strict) ===\033[0m"

  install_xrt "$TMP" "${XRT_FILES[@]}"
  load_kernel_modules

  download_deployment_target_packages "$TMP" "${DEPLOY_FILES[@]}"

  BDF=$(find_u250_bdf)
  echo "U250 found: $BDF"

  source /opt/xilinx/xrt/setup.sh

  CUR_SHELL=$(get_current_shell "$BDF")
  echo "Current shell: $CUR_SHELL"

  FLAG_VALUE=$(cat "$BASE_PROGRAM_STATUS_FLAG" 2>/dev/null || echo "")

  flash_partitions "$CUR_SHELL" "$FLAG_VALUE" "$BDF" \
    "$TARGET_SHELL" "$TARGET_SHELL_DIR" \
    "$BASE_PROGRAM_STATUS_FLAG"

  # Проверка готовности устройства после прошивки
  if ! check_device_ready "$BDF"; then
    echo -e "\e[31m[ERR] Device $BDF is not ready after flashing.\e[0m"
    exit 1
  fi

  install_vitis_ai_runtime "$VAI_HOME" "$OVERLAY_IP"

  sudo apt autoremove -y

  # Проверка и валидация Overlay‑xclbin
  if ! ls /opt/xilinx/overlaybins/"$OVERLAY_IP"/*/dpu.xclbin &>/dev/null; then
    echo -e "\e[31m[ERR] Overlay $OVERLAY_IP not found after deploy.\e[0m"
    exit 1
  fi
  echo "Overlay $OVERLAY_IP OK."

  echo "Running 'xbutil validate --device $BDF --report basic platform'"
  sudo xbutil validate --device "$BDF" --report basic --report platform

  echo -e "\e[32mU250 is ready - XRT, deployment packages, shell, and overlay validated.\e[0m"
}

main "$@"
