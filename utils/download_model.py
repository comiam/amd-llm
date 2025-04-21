#!/usr/bin/env python3

import os
import argparse
from typing import Any, Literal
import yaml
from transformers import AutoTokenizer, AutoModelForCausalLM


def load_config(config_path) -> Any:
    """Загрузка конфигурационного файла."""
    with open(config_path, "r") as f:
        return yaml.safe_load(f)


def download_model(model_name, output_dir) -> Literal[True]:
    """Загрузка модели с использованием transformers."""
    print(f"Загрузка токенизатора {model_name}...")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    tokenizer.save_pretrained(output_dir)

    print(f"Загрузка модели {model_name}...")
    model = AutoModelForCausalLM.from_pretrained(
        model_name, device_map="auto", trust_remote_code=True
    )
    model.save_pretrained(output_dir)

    print(f"Модель сохранена в {output_dir}")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download Transformer model")
    parser.add_argument("--config", type=str, required=True, help="Path to config.yaml")
    args = parser.parse_args()

    config = load_config(args.config)
    model_name = config["model"]["repo_id"]
    model_dir = os.path.join(config["paths"]["models_dir"], config["model"]["name"])

    os.makedirs(model_dir, exist_ok=True)
    download_model(model_name, model_dir)
