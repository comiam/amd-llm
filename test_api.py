#!/usr/bin/env python3

import argparse
import json
import requests
import time
import yaml

def load_config(config_path):
    """Загрузка конфигурационного файла."""
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)

def test_generate(url, prompt, max_tokens=None, temperature=None):
    """Тест генерации текста через API."""
    headers = {
        "Content-Type": "application/json",
    }
    
    data = {
        "prompt": prompt,
    }
    
    if max_tokens is not None:
        data["max_tokens"] = max_tokens
    
    if temperature is not None:
        data["temperature"] = temperature
    
    print(f"\nОтправка запроса на {url}:")
    print(f"Промпт: {prompt}")
    
    start_time = time.time()
    response = requests.post(url, headers=headers, json=data)
    end_time = time.time()
    
    print(f"Статус ответа: {response.status_code}")
    
    if response.status_code == 200:
        result = response.json()
        print("\nСгенерированный текст:")
        print(f"{result['text']}")
        print("\nСтатистика:")
        print(f"Токены промпта: {result['usage']['prompt_tokens']}")
        print(f"Токены ответа: {result['usage']['completion_tokens']}")
        print(f"Всего токенов: {result['usage']['total_tokens']}")
        print(f"Причина завершения: {result['finish_reason']}")
        print(f"Время генерации: {result['duration_ms']:.2f}ms")
        print(f"Время запроса: {(end_time - start_time) * 1000:.2f}ms")
    else:
        print(f"Ошибка: {response.text}")

def test_status(url):
    """Проверка статуса сервера."""
    print(f"\nПроверка статуса сервера {url}:")
    try:
        response = requests.get(url)
        print(f"Статус ответа: {response.status_code}")
        if response.status_code == 200:
            print("Информация о сервере:")
            print(json.dumps(response.json(), indent=2, ensure_ascii=False))
        else:
            print(f"Ошибка: {response.text}")
    except Exception as e:
        print(f"Ошибка соединения: {str(e)}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Тестирование API сервера инференса")
    parser.add_argument("--config", type=str, default="../configs/config.yaml", help="Путь к конфигурационному файлу")
    parser.add_argument("--host", type=str, help="Хост сервера")
    parser.add_argument("--port", type=int, help="Порт сервера")
    parser.add_argument("--prompt", type=str, default="Привет! Расскажи мне о AMD Alveo U250.", help="Промпт для генерации")
    parser.add_argument("--max-tokens", type=int, help="Максимальное количество токенов для генерации")
    parser.add_argument("--temperature", type=float, help="Параметр temperature для генерации")
    parser.add_argument("--status", action="store_true", help="Проверить только статус сервера")
    
    args = parser.parse_args()
    
    # Загружаем конфигурацию если не указаны хост и порт
    if not args.host or not args.port:
        config = load_config(args.config)
        host = args.host or config["server"]["host"]
        port = args.port or config["server"]["port"]
    else:
        host = args.host
        port = args.port
    
    base_url = f"http://{host}:{port}"
    
    if args.status:
        test_status(base_url)
    else:
        test_status(base_url)
        test_generate(
            url=f"{base_url}/v1/generate",
            prompt=args.prompt,
            max_tokens=args.max_tokens,
            temperature=args.temperature
        )
