#!/usr/bin/env python3
"""Convert HuggingFace model to XIR/TVM for AMD Alveo U250.

1. On the host we export a TorchScript graph and gather a small calibration
   dataset (CodeSearchNet).  You can set ``HF_TOKEN`` to access private splits.
2. Quantization and compilation run inside ``xilinx/vitis-ai`` Docker via
   ``quant_compile.py``.
3. Resulting ``.xmodel`` is also packed as a TVM bundle.

• TorchScript export:
  https://pytorch.org/tutorials/advanced/cpp_export.html
• Vitis-AI quantization doc:
  https://docs.xilinx.com/r/2.5-English/ug1414-vitis-ai
"""

import argparse
import random
import subprocess
from pathlib import Path



def run(cmd: str) -> None:
    """Run a shell command."""
    subprocess.check_call(cmd, shell=True)


def export_torchscript(mdir: Path, seq_len: int) -> Path:
    out_dir = mdir / "torchscript"
    out_dir.mkdir(exist_ok=True)
    ts_path = out_dir / "model.ts"

    cmd = f"python - <<'PY'\n" \
          f"from transformers import AutoModelForCausalLM, AutoTokenizer\n" \
          f"import torch\n" \
          f"tok = AutoTokenizer.from_pretrained('{mdir}')\n" \
          f"mdl = AutoModelForCausalLM.from_pretrained('{mdir}', torch_dtype=torch.float16, device_map='cpu', low_cpu_mem_usage=True)\n" \
          f"mdl.eval()\n" \
          f"ex = tok.encode('def hello():\n    pass', return_tensors='pt')[:,:{seq_len}]\n" \
          f"with torch.no_grad():\n" \
          f"    ts = torch.jit.trace(mdl, ex, strict=False)\n" \
          f"ts.save('{ts_path}')\n" \
          f"PY"
    run(cmd)
    return ts_path


def make_calib_dataset(mdir: Path) -> Path:
    droot = mdir / "calib"
    droot.mkdir(exist_ok=True)
    cmd = (
        "python - <<'PY'\n"
        "from datasets import load_dataset\n"
        "import random, pathlib, os\n"
        f"d = pathlib.Path('{droot}')\n"
        "token = os.getenv('HF_TOKEN')\n"
        "ds = load_dataset('code_search_net','python',split='train[:0.1%]', trust_remote_code=True, token=token)\n"
        "for i,ex in enumerate(random.sample(list(ds),256)):\n"
        "    (d/f'{i}.txt').write_text(ex['code'])\n"
        "print('[calib] written to', d)\n"
        "PY"
    )
    run(cmd)
    return droot


def run_docker_quant_compile(mdir: Path, precision: str, quant_mode: str, seq_len: int) -> None:
    """Spawn the Vitis-AI container to quantize and compile the model."""
    repo_root = Path(__file__).resolve().parent.parent
    cmd = [
        "docker", "run", "--rm",
        "-v", f"{mdir}:/model",
        "-v", f"{repo_root}:/repo",
        "-w", "/repo",
        "xilinx/vitis-ai:2.5.0.1260",
        "python", "utils/quant_compile.py",
        "--model-dir", "/model",
        "--precision", precision,
        "--quant-mode", quant_mode,
        "--seq-len", str(seq_len),
    ]
    run(" ".join(cmd))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True, help="Path to HF model")
    parser.add_argument("--precision", default="int8", help="Quantization precision")
    parser.add_argument("--seq-len", type=int, default=2048)
    parser.add_argument("--quant-mode", default="calib", help="calib or test")
    parser.add_argument("--xclbin")  # ignored, kept for backward compatibility
    args = parser.parse_args()

    mdir = Path(args.model_dir)
    export_torchscript(mdir, args.seq_len)
    make_calib_dataset(mdir)
    run_docker_quant_compile(mdir, args.precision, args.quant_mode, args.seq_len)
    print("[✓] Model converted ->", mdir / "compile/qwen_u250.xmodel")
