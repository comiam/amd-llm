#!/usr/bin/env python3
"""Quantize and compile model inside a Vitis-AI Docker container."""
import argparse
import subprocess
from pathlib import Path

import tvm
from tvm import relay

ARCH = "/opt/vitis_ai/compiler/arch/DPUCADF8H/U250/arch.json"


def run(cmd: str) -> None:
    subprocess.check_call(cmd, shell=True)


def quantize(ts: Path, calib: Path, mode: str, out_dir: Path) -> Path:
    out_dir.mkdir(exist_ok=True)
    run(
        f"vai_q_pytorch quantize --input_model {ts} --calib_data {calib} "
        f"--output_dir {out_dir} --quant_mode {mode} --target DPUCADF8H"
    )
    return out_dir / "deploy_model_int.xmodel"


def compile_xmodel(xmodel: Path, out_dir: Path) -> Path:
    out_dir.mkdir(exist_ok=True)
    run(
        f"vai_c_xir -x {xmodel} -a {ARCH} -o {out_dir} -n qwen_u250 "
        f"-e '{{\"mode\":\"normal\",\"batchsize\":1}}'"
    )
    return out_dir / "qwen_u250.xmodel"


def tvm_pack(xmodel: Path, out_dir: Path) -> None:
    mod, params = relay.frontend.from_xmodel(str(xmodel))
    tgt = tvm.target.Target("llvm -device=vitis-ai")
    with tvm.transform.PassContext(opt_level=3):
        lib = relay.build(mod, tgt, params=params)
    out_dir.mkdir(exist_ok=True)
    lib.export_library(out_dir / "model_alveo.so")
    with open(out_dir / "model_alveo.params", "wb") as f:
        f.write(relay.save_param_dict(lib.get_params()))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--model-dir", required=True)
    p.add_argument("--precision", default="int8")
    p.add_argument("--quant-mode", default="calib")
    p.add_argument("--seq-len", type=int, default=2048)
    args = p.parse_args()

    mdir = Path(args.model_dir)
    ts = mdir / "torchscript" / "model.ts"
    calib = mdir / "calib"
    qdir = mdir / "quant"
    cdir = mdir / "compile"
    tvmdir = mdir / "alveo"

    qx = quantize(ts, calib, args.quant_mode, qdir)
    xmodel = compile_xmodel(qx, cdir)
    tvm_pack(xmodel, tvmdir)
    print("[✓] XMODEL ->", xmodel)


if __name__ == "__main__":
    main()
