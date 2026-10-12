#!/usr/bin/env python3
"""One-time export of EmbeddingGemma 2's text encoder to OpenVINO IR for embedsearch.

Runs in a throwaway venv with PyTorch (see requirements-export.txt); the search service itself
only needs OpenVINO + tokenizers. Writes embeddinggemma2_text.{xml,bin} (float16 weights) and
tokenizer.json into --out, then checks the exported model against PyTorch.

    python export_model.py --out ~/.local/share/embedsearch/model
"""

import argparse
import shutil
import sys
from pathlib import Path

import numpy as np
import openvino as ov
import torch
from huggingface_hub import hf_hub_download
from sentence_transformers import SentenceTransformer

MODEL_ID = "google/embeddinggemma-2"
REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"  # the snapshot this project was built and tested with


class Embedder(torch.nn.Module):
    """Transformer + mean pooling + L2 normalise: the sentence-transformers pipeline as one graph."""

    def __init__(self, auto_model):
        super().__init__()
        self.auto_model = auto_model

    def forward(self, input_ids, attention_mask):
        h = self.auto_model(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(h.dtype)
        pooled = (h * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, dim=-1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    out = args.out.expanduser()
    out.mkdir(parents=True, exist_ok=True)

    print(f"loading {MODEL_ID}@{REVISION[:8]} (text encoder only, float32)")
    st = SentenceTransformer(MODEL_ID, revision=REVISION, device="cpu",
                             model_kwargs={"torch_dtype": torch.float32},
                             config_kwargs={"vision_config": None, "audio_config": None})
    st.eval()
    embedder = Embedder(st[0].auto_model).eval()

    def features(texts):
        f = st.tokenize(texts)
        return f["input_ids"], f["attention_mask"]

    print("converting to OpenVINO IR")
    ids, mask = features(["title: none | text: hello world", "task: search result | query: example"])
    with torch.no_grad():
        model = ov.convert_model(
            embedder,
            example_input={"input_ids": ids, "attention_mask": mask},
            input=[("input_ids", ov.PartialShape([-1, -1]), ov.Type.i64),
                   ("attention_mask", ov.PartialShape([-1, -1]), ov.Type.i64)],
        )
    xml = out / "embeddinggemma2_text.xml"
    ov.save_model(model, xml, compress_to_fp16=True)
    shutil.copy(hf_hub_download(MODEL_ID, "tokenizer.json", revision=REVISION), out / "tokenizer.json")

    # Check short inputs and inputs past the 512-token sliding window, on CPU in float32.
    words = ("The northern lights are caused by charged particles from the sun colliding with gases in the "
             "upper atmosphere, and glaciers carve valleys as they slowly advance and retreat. ").split()
    texts = ["title: none | text: sourdough relies on wild yeast",
             "task: search result | query: what causes the aurora?",
             "title: none | text: " + " ".join(words * 30)]
    compiled = ov.Core().compile_model(xml, "CPU", {"INFERENCE_PRECISION_HINT": "f32"})
    worst = 1.0
    for t in texts:
        i, m = features([t])
        with torch.no_grad():
            ref = embedder(i, m).numpy()
        got = compiled({"input_ids": i.numpy(), "attention_mask": m.numpy()})[compiled.output(0)]
        got /= np.linalg.norm(got, axis=1, keepdims=True)
        worst = min(worst, float((ref * got).sum()))
    print(f"exported to {out} (worst cosine vs PyTorch: {worst:.5f})")
    if worst < 0.999:
        sys.exit("export check failed: OpenVINO output does not match PyTorch")


if __name__ == "__main__":
    main()
