#!/usr/bin/env python3
"""
HF -> TorchScript -> quantize 8‑bit (vai_q_pytorch) -> compile (vai_c_xir) ->
TVM runtime bundle.

• TorchScript export:
  https://pytorch.org/tutorials/advanced/cpp_export.html
• Quantizer doc:
  https://docs.xilinx.com/r/2.5-English/ug1414-vitis-ai
"""

import argparse, os, subprocess, tvm
from tvm import relay

run = lambda cmd: subprocess.check_call(cmd, shell=True)

ARCH = "/opt/vitis_ai/compiler/arch/DPUCADF8H/U250/arch.json"


def export_ts(src_dir, out_ts):
    run(
        f"python - <<'PY'\n"
        f"from transformers import AutoModelForCausalLM, AutoTokenizer\n"
        f"import torch\n"
        f"tok = AutoTokenizer.from_pretrained('{src_dir}')\n"
        f"mdl = AutoModelForCausalLM.from_pretrained('{src_dir}', torchscript=True)\n"
        f"t = tok.encode('Hello', return_tensors='pt')\n"
        f"ts = torch.jit.trace(mdl, t)\n"
        f"ts.save('{out_ts}')\n"
        f"PY"
    )
    return out_ts


def quantize(ts, prec):
    run(
        f"vai_q_pytorch quantize --model {ts} --input_fn dummy_input "
        f"--output_dir quant --quant_mode {prec} --target DPUCADF8H"
    )
    return "quant/model_int.xmodel"


def compile_xmodel(xmodel):
    run(
        f"vai_c_xir -x {xmodel} -a {ARCH} -o compile -n llama_u250 "
        f'-e \'{{"mode":"normal","batchsize":1}}\''
    )
    return "compile/llama_u250.xmodel"


def tvm_pack(xmodel):
    mod, params = relay.frontend.from_xmodel(xmodel)
    tgt = tvm.target.Target("llvm -device=vitis-ai")
    with tvm.transform.PassContext(opt_level=3):
        lib = relay.build(mod, tgt, params=params)
    os.makedirs("alveo", exist_ok=True)
    lib.export_library("alveo/model_alveo.so")
    with open("alveo/model_alveo.params", "wb") as f:
        f.write(relay.save_param_dict(lib.get_params()))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--model-dir", required=True)
    p.add_argument("--precision", default="int8")
    a = p.parse_args()

    os.chdir(a.model_dir)
    xmodel = quantize(export_ts(".", "model.ts"), a.precision)
    compile_xmodel(xmodel)
    tvm_pack("compile/llama_u250.xmodel")
