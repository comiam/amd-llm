# AMD Alveo U250 ― LLM Inference Stack

> **Задача** - запустить любой HF‑трансформер (по‑умолчанию Qwen 2.5‑32B)  
> на FPGA‑карте **AMD Alveo U250** под Ubuntu 20.04 LTS.

Проект включает:

| Каталог / файл | Содержание |
|----------------|-----------|
| `scripts/` | 4 скрипта пошаговой установки + _умный_ `setup_all.sh` |
| `utils/`   | загрузка модели, конвертация -> xmodel -> TVM, FastAPI‑сервер, тест‑клиент |
| `configs/config.yaml` | базовая конфигурация путей, сервера и дефолт‑параметров генерации |
| `setup_env.sh` | активация окружения XRT + Vitis‑AI |
| `setup_all.sh` | идемпотентный мастер‑скрипт для установки всех зависимостей |

---

## 0  Системные требования

| компонент | минимально |
|-----------|-----------|
| ОС        | Ubuntu 20.04.6 LTS, kernel >= 5.4 |
| HW        | AMD Alveo U250 (DPUCADF8H) |
| RAM / SSD | >= 64 GB RAM, >= 500 GB SSD |
| Сеть      | Доступ в интернет (Xilinx / PyPI / HuggingFace) |

---

## 1  Quick‑Start

```bash
git clone https://github.com/your-name/amd-llm-u250.git
cd amd-llm-u250
chmod +x setup_all.sh
sudo ./setup_all.sh           # ШАГ 1: базовые пакеты + venv   -> reboot
sudo ./setup_all.sh           # ШАГ 2: XRT + overlay           -> reboot
# после перезагрузки ВЫПОЛНИТЕ выведенную команду xbmgmt partition
sudo ./setup_all.sh           # ШАГ 3: конвертация модели      -> сервер запущен
```

URL API по умолчанию - **`http://0.0.0.0:8000/v1/generate`**.

Тест:

```bash
python test_api.py --prompt "Расскажи про FPGA Alveo U250" \
                         --temperature 0.8 --top-p 0.9 --top-k 40
```

---

## 2  Схема пайплайна

```
HuggingFace model
        │
        ▼  (TorchScript export)
model.ts
        │
        ▼  vai_q_pytorch   – INT8 PTQ
model_int.xmodel
        │
        ▼  vai_c_xir       – компиляция под DPUCADF8H
llama_u250.xmodel
        │
        ▼  TVM Relay -> LLVM (vitis‑ai backend)
model_alveo.{so,params}
        │
        ▼  FastAPI server  +  sampling loop (temperature / top‑p / top‑k / rep.pen.)
REST API
```

*TVM граф выполняет **один шаг**; autoregressive‑петля и sampling крутятся на CPU.*

---

## 3  Конфигурация - `configs/config.yaml`

| ключ | значение по умолчанию | описание |
|------|-----------------------|----------|
| `paths.*` | base, models, logs | пути в файловой системе |
| `model.repo_id` | `Qwen/Qwen2.5-32B` | HuggingFace ID |
| `model.precision` | `int8` | quant mode (`int8` / `fp16`). INT4 требует ручного PTQ. |
| `alveo.xclbin` | `/opt/xilinx/overlaybins/DPUCADF8H/*/dpu.xclbin` | прошивка карты |
| `server.*` | host + port | адрес API |
| `inference.*` | temperature, top_p, ... | параметры по умолчанию |

Измените файл - и `setup_all.sh` пересоберёт **только** необходимые стадии.

---

## 4  Описание скриптов

| файл | комментарий |
|------|-------------|
| `setup_all.sh` | идемпотентный мастер: проверяет venv, XRT/overlay, модель, сервер |
| `scripts/01_prepare_system.sh` | системные пакеты + venv |
| `scripts/02_prepare_alveo_for_llm.sh` | запускает официальный `install.sh` (Vitis‑AI 2.5) и показывает команду `xbmgmt partition` с авто‑определённым BDF |
| `scripts/03_prepare_qwen_model.sh` | вызывает Python‑утилиты download / convert / pack |
| `scripts/04_run_inference_server.sh` | стартует FastAPI под Uvicorn |
| `utils/download_model.py` | скачивает модель + токенизатор из HF |
| `utils/convert_model_for_alveo.py` | host‑export + docker‑квант/compile |
| `utils/inference_server.py` | сервер; sampling портирован из MLPerf 2.1 `sampling.cpp` |
| `test_api.py` | CLI‑клиент для проверки REST |

---

## 5  Параметры генерации

| поле JSON | действие |
|-----------|----------|
| `max_tokens` | длина выдачи |
| `temperature` | сглаживание logits |
| `top_p` | nucleus sampling |
| `top_k` | отфильтровывать всё, кроме `k` самых вероятных |
| `repetition_penalty` | штраф за повтор токенов |
| `stop` | список стоп‑строк (массив) |

Пример запроса:

```json
POST /v1/generate
{
  "prompt": "Translate to French: \"Good morning.\"",
  "max_tokens": 32,
  "temperature": 0.7,
  "top_p": 0.9,
  "top_k": 40,
  "repetition_penalty": 1.1
}
```

---

## 6  Тонкости и частые вопросы

* **INT4**. `vai_q_pytorch` 2.5 официально поддерживает только INT8.  
  INT4 PTQ выполняется офлайн‑скриптом `vai_ptq_tool.py`; добавьте свою
  статистику и поправьте `convert_model_for_alveo.py`.

* **Несколько U250** - в `02_prepare_alveo...` PCIe‑адрес выбирается первым
  из `lspci -d 10ee:`; при необходимости укажите свой `--card` вручную.

* **Прошивка shell** - выполняется *один* раз после перезагрузки; если
  сервер не видит карту, проверьте `xbmgmt examine`.

* **Производительность** - 32B‑модель на U250 (INT8) ≈ 10 token/s (batch = 1).

---

## 7  Лицензия

Код проекта распространяется под лицензией Apache 2.0.
Все бинарники Xilinx/AMD - согласно их собственным лицензионным соглашениям  
(см. EULA при запуске `install.sh`).

---

Автор: comiam
