#!/usr/bin/env python3
# FastAPI‑сервер для Alveo U250 LLM

import argparse
import logging
import os
import time
import yaml
from typing import Any, Dict, List, Optional

import torch
import torch.nn.functional as F
import tvm
from tvm.contrib import graph_executor
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from transformers import AutoTokenizer

# -- Логирование --------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s"
)
log = logging.getLogger("server")


# -- Pydantic модели ----------------------------------------------------------
class GenerationRequest(BaseModel):
    prompt: str
    max_tokens: Optional[int] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    top_k: Optional[int] = None
    repetition_penalty: Optional[float] = None
    stop: Optional[List[str]] = None


class GenerationResponse(BaseModel):
    text: str
    usage: Dict[str, int]
    finish_reason: str
    duration_ms: float


# -- Sampling helper ----------------------------------------------------------
def sample_token(
    logits: torch.Tensor,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    hist_ids: torch.Tensor,
) -> int:
    """Вернёт id следующего токена."""
    logits = logits / temperature
    for tid in set(hist_ids.tolist()):
        logits[0, tid] /= repetition_penalty

    if top_k > 0:
        kth = torch.topk(logits, top_k)[0][:, -1, None]
        logits[logits < kth] = -float("inf")

    if top_p < 1.0:
        sort_logits, sort_idx = torch.sort(logits, descending=True)
        probs = F.softmax(sort_logits, dim=-1)
        cum = torch.cumsum(probs, dim=-1)
        sort_logits[cum > top_p] = -float("inf")
        logits = torch.zeros_like(logits).scatter(1, sort_idx, sort_logits)

    probs = F.softmax(logits, dim=-1)
    return torch.multinomial(probs, num_samples=1).item()


# -- Движок инференса ---------------------------------------------------------
class AlveoEngine:
    def __init__(self, cfg: Dict) -> None:
        mdl_dir = os.path.join(
            cfg["paths"]["models_dir"],
            cfg["model"]["name"],
        )
        self.tokenizer = AutoTokenizer.from_pretrained(mdl_dir)

        lib = tvm.runtime.load_module(
            os.path.join(mdl_dir, "alveo/model_alveo.so")
        )
        self.mod = graph_executor.GraphModule(
            lib["default"](tvm.device("opencl", 0))
        )
        params_path = os.path.join(mdl_dir, "alveo/model_alveo.params")
        with open(params_path, "rb") as f:
            self.mod.load_params(
                tvm.runtime.load_param_dict(f.read())
            )

        self.defaults = cfg["inference"]

    # ---------------------------------------------------------------------
    def generate(self, req: GenerationRequest) -> GenerationResponse:
        t0 = time.time()

        def param(key):
            return getattr(req, key) or self.defaults[key]

        T, TP, TK = param("temperature"), param("top_p"), param("top_k")
        MAX, RP = param("max_tokens"), param("repetition_penalty")

        in_ids = torch.tensor(
            [self.tokenizer.encode(req.prompt, add_special_tokens=False)]
        )
        gen_ids = in_ids.clone()

        for _ in range(MAX):
            attn = torch.ones_like(gen_ids)
            self.mod.set_input(
                "input_ids", tvm.nd.array(gen_ids.numpy().astype("int64"))
            )
            self.mod.set_input(
                "attention_mask", tvm.nd.array(attn.numpy().astype("int64"))
            )
            self.mod.run()
            logits = torch.from_numpy(self.mod.get_output(0).numpy())

            nid = sample_token(logits[:, -1, :], T, TP, TK, RP, gen_ids[0])
            gen_ids = torch.cat([gen_ids, torch.tensor([[nid]])], dim=1)

            if nid == self.tokenizer.eos_token_id:
                break
            if req.stop and any(
                s in self.tokenizer.decode(
                    gen_ids[0], skip_special_tokens=True
                )
                for s in req.stop
            ):
                break

        out_txt = self.tokenizer.decode(
            gen_ids[0][len(in_ids[0]):], skip_special_tokens=True
        )
        dur = (time.time() - t0) * 1000
        return GenerationResponse(
            text=out_txt,
            usage={
                "prompt_tokens": len(in_ids[0]),
                "completion_tokens": len(gen_ids[0]) - len(in_ids[0]),
                "total_tokens": len(gen_ids[0]),
            },
            finish_reason=(
                "stop" if nid == self.tokenizer.eos_token_id else "length"
            ),
            duration_ms=dur,
        )


# -- FastAPI обёртка -------------------------------
def load_cfg(pth) -> Any:
    return yaml.safe_load(open(pth, "r"))


def create_app(cfg_path: str) -> Any:
    cfg = load_cfg(cfg_path)
    eng = AlveoEngine(cfg)

    app = FastAPI()
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
    )

    @app.get("/")
    def status() -> Dict[str, Any]:
        return {
            "model": cfg["model"]["name"],
            "precision": cfg["model"]["precision"],
        }

    @app.post("/v1/generate", response_model=GenerationResponse)
    def gen(r: GenerationRequest) -> GenerationResponse:
        try:
            return eng.generate(r)
        except Exception as e:
            log.exception("generate failed")
            raise HTTPException(status_code=500, detail=str(e))

    return app


if __name__ == "__main__":
    arg = argparse.ArgumentParser()
    arg.add_argument("--config", required=True)
    a = arg.parse_args()
    c = load_cfg(a.config)

    import uvicorn

    uvicorn.run(
        create_app(a.config),
        host=c["server"]["host"],
        port=c["server"]["port"],
    )
