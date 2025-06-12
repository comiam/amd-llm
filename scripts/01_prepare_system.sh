#!/usr/bin/env bash
################################################################################
# STEP‑0  -  базовая подготовка Ubuntu 20.04 LTS
#
# Источники:
#   * Vitis‑AI 2.5 README (https://github.com/Xilinx/Vitis-AI/blob/v2.5/setup/alveo/README.md)
#   * TVM Installation Guide (https://tvm.apache.org/docs/install/from_source.html#install-from-source)
################################################################################

set -euo pipefail
CFG="configs/config.yaml"

# Проверка архитектуры
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo "Ошибка: скрипт поддерживает только x86_64 архитектуру, обнаружена: $ARCH"
    exit 1
fi

sudo apt update && sudo apt -y upgrade
sudo apt install -y build-essential git wget jq cmake dkms pciutils \
    bzip2 libglib2.0-0 libxext6 libsm6 libxrender1
sudo snap install yq

BASE="$(yq '.paths.base_dir' "$CFG")"
mkdir -p "$BASE"

# === Conda-окружение ===
# Папка для окружения
ENV_DIR="${ENV_DIR:-$BASE}"
INSTALL_TVM=0
for arg in "$@"; do
    if [ "$arg" == "--install-tvm" ]; then
        INSTALL_TVM=1
    fi
    if [ "$arg" == "--env-dir" ]; then
        ENV_DIR="$2"
        shift
    fi
    shift
done

# Проверяем Python >=3.8
if ! command -v python3 &>/dev/null; then
    echo "Ошибка: нужен Python 3.8+. Установите Python 3."
    exit 1
fi
PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if [[ $(echo -e "$PYVER\n3.8" | sort -V | head -n1) != "3.8" ]]; then
    echo "Ошибка: ваша версия Python 3 (${PYVER}) < 3.8."
    exit 1
fi

# Установка Miniconda, если нужно
if ! command -v conda &>/dev/null; then
    echo "Conda не найдена — ставим Miniconda в $ENV_DIR/miniconda..."
    INSTALLER="Miniconda3-latest-Linux-x86_64.sh"
    wget --quiet "https://repo.anaconda.com/miniconda/$INSTALLER" -O "/tmp/$INSTALLER"
    bash "/tmp/$INSTALLER" -b -p "$ENV_DIR/miniconda"
    export PATH="$ENV_DIR/miniconda/bin:$PATH"
fi

# Инициализируем conda в bash
source "$ENV_DIR/miniconda/etc/profile.d/conda.sh"
eval "$(conda shell.bash hook)"

# Создаём (или активируем) окружение
if [ ! -d "$ENV_DIR/env" ]; then
    echo "Создаём conda-окружение с Python>=3.8 в $ENV_DIR/env..."
    conda create -y -p "$ENV_DIR/env" python=3.8
else
    echo "Окружение уже существует в $ENV_DIR/env, активируем..."
fi
conda activate "$ENV_DIR/env"

CHANNELS="-c conda-forge"

# CMake >=3.24
REQ_CMAKE="3.24.0"
INST_CMAKE_VER=$(cmake --version 2>/dev/null | head -n1 | awk '{print $3}' || echo "0")
if ! command -v cmake &>/dev/null || [[ $(echo -e "$INST_CMAKE_VER\n$REQ_CMAKE" | sort -V | head -n1) != "$REQ_CMAKE" ]]; then
    echo "Устанавливаем CMake >= $REQ_CMAKE..."
    conda install -y $CHANNELS "cmake>=$REQ_CMAKE"
fi

# LLVM >=15 и Clang >=5.0
REQ_LLVM="15"
INST_LLVM_VER=$(llvm-config --version 2>/dev/null || echo "0")
if ! command -v llvm-config &>/dev/null || [[ $(echo -e "$INST_LLVM_VER\n$REQ_LLVM" | sort -V | head -n1) != "$REQ_LLVM" ]]; then
    echo "Устанавливаем LLVM >= $REQ_LLVM..."
    conda install -y $CHANNELS "llvmdev>=$REQ_LLVM"
fi
REQ_CLANG="5.0"
INST_CLANG_VER=$(clang --version 2>/dev/null | head -n1 | sed -E 's/.*version ([0-9]+\.[0-9]+).*/\1/' || echo "0")
if ! command -v clang &>/dev/null || [[ $(echo -e "$INST_CLANG_VER\n$REQ_CLANG" | sort -V | head -n1) != "$REQ_CLANG" ]]; then
    echo "Устанавливаем Clang >= $REQ_CLANG..."
    conda install -y $CHANNELS clangdev clangxx_linux-64
fi

# GCC >=7.1
REQ_GCC="7.1"
INST_GCC_VER=$(gcc -dumpversion 2>/dev/null || echo "0")
if ! command -v gcc &>/dev/null || [[ $(echo -e "$INST_GCC_VER\n$REQ_GCC" | sort -V | head -n1) != "$REQ_GCC" ]]; then
    echo "Устанавливаем GCC >= $REQ_GCC..."
    conda install -y $CHANNELS gcc_linux-64 gxx_linux-64
fi

# Git
if ! command -v git &>/dev/null; then
    echo "Устанавливаем git..."
    conda install -y $CHANNELS git
fi

# Установка зависимостей из requirements.txt
if [ -f "requirements.txt" ]; then
    echo "Устанавливаем pip-зависимости из requirements.txt..."
    pip install -r requirements.txt
fi

# Функция сравнения версий: version_ge INSTALLED REQ -> true, если INSTALLED >= REQ
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -C -V
}

# После установки Miniconda
rm -f "/tmp/$INSTALLER"

echo -e "\e[32m[01] System packages & conda env installed.\e[0m"

echo
if [ $INSTALL_TVM -eq 1 ]; then
    echo "TVM установлен и готов к использованию."
    echo "Для использования TVM в других сессиях, выполните:"
    echo "  export TVM_LIBRARY_PATH=\"$BASE/tvm/build\""
fi
echo "Готово! Чтобы начать работу, выполните:"
echo "  conda activate \"$ENV_DIR/env\""

# Установка TVM из исходников, если запрошено
if [ $INSTALL_TVM -eq 1 ]; then
    echo "Начинаем установку TVM из исходников..."

    # Устанавливаем дополнительные зависимости для TVM
    conda install -y $CHANNELS "llvmdev>=15" "cmake>=3.24" git python=3.11

    # Клонируем репозиторий TVM
    if [ ! -d "$BASE/tvm" ]; then
        git clone --recursive https://github.com/apache/tvm "$BASE/tvm"
    else
        echo "Директория tvm уже существует, используем её..."
        cd "$BASE/tvm" && git pull && git submodule update --init --recursive && cd "$BASE"
    fi

    # Создаём build директорию и настраиваем сборку
    cd "$BASE/tvm"
    rm -rf build && mkdir build && cd build
    cp ../cmake/config.cmake .

    # Настраиваем параметры сборки
    echo "set(CMAKE_BUILD_TYPE RelWithDebInfo)" >>config.cmake
    echo "set(USE_LLVM \"llvm-config --ignore-libllvm --link-static\")" >>config.cmake
    echo "set(HIDE_PRIVATE_SYMBOLS ON)" >>config.cmake
    echo "set(USE_CUDA   OFF)" >>config.cmake
    echo "set(USE_METAL  OFF)" >>config.cmake
    echo "set(USE_VULKAN OFF)" >>config.cmake
    echo "set(USE_OPENCL OFF)" >>config.cmake
    echo "set(USE_CUBLAS OFF)" >>config.cmake
    echo "set(USE_CUDNN  OFF)" >>config.cmake
    echo "set(USE_CUTLASS OFF)" >>config.cmake

    # Сборка TVM
    echo "Собираем TVM..."
    cmake .. && cmake --build . --parallel $(nproc)

    # Устанавливаем Python-пакеты
    TVM_PATH=$(pwd)
    cd ..
    export TVM_LIBRARY_PATH="$TVM_PATH"
    pip install -e python

    # Проверка корректности установки
    echo "Проверяем установку TVM..."
    python -c "import tvm; print('TVM успешно установлен в:', tvm.__file__)"
    python -c "import tvm; print('TVM библиотека:', tvm._ffi.base._LIB)"
    python -c "import tvm; print('TVM информация о библиотеках:\\n' + '\\n'.join(f'{k}: {v}' for k, v in tvm.support.libinfo().items()))"

    cd "$BASE"
    echo "TVM успешно установлен!"
fi
