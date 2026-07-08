"""Optional BiRefNet sticker backend for the Kida Mac server.

Kept out of kida_vlm_server.py so the base server stays dependency-free. This module
is only imported when the /object/sticker endpoint is hit, and only works if the
sticker extras are installed:

    pip install -r Server/requirements-sticker.txt        # rembg + onnxruntime (CPU)
    pip install -r Server/requirements-sticker-gpu.txt    # torch + BiRefNet (Apple GPU, ~1.4s)

BiRefNet is automatic salient-object matting (no prompt) — best cutout quality, but a
heavy model, so this is the "better when home" tier. The on-device SAM path is the
real-time / offline fallback.

Two backends, auto-selected (override with KIDA_STICKER_BACKEND=torch|rembg):
  * torch — full BiRefNet on the Apple GPU (MPS) via transformers, ~1.4s, best quality.
  * rembg — birefnet-general-lite on CPU (onnxruntime), ~5.8s, no torch needed.
"""
from __future__ import annotations

import hashlib
import io
import os
import sys
from collections import OrderedDict

_SESSION = None        # rembg session (lazy)
_TORCH_MODEL = None    # (model, device) for the torch-MPS backend (lazy)
_BACKEND = None        # "torch" | "rembg", decided once

# ponytail: in-memory LRU keyed on image hash; lost on restart. Add a disk cache if
# repeat stickers need to survive restarts.
_CACHE: "OrderedDict[str, tuple[bytes, tuple[int, int]]]" = OrderedDict()
_CACHE_MAX = 64


def _torch_ok() -> bool:
    try:
        import torch, transformers  # noqa: F401
        return True
    except Exception:
        return False


def _rembg_ok() -> bool:
    try:
        import rembg  # noqa: F401
        return True
    except Exception:
        return False


def available() -> bool:
    """True if any sticker backend can run (torch-MPS or rembg)."""
    return _torch_ok() or _rembg_ok()


def _backend() -> str:
    """Pick the matting backend once: 'torch' (Apple GPU, best) else 'rembg' (CPU)."""
    global _BACKEND
    if _BACKEND is None:
        forced = os.environ.get("KIDA_STICKER_BACKEND")
        _BACKEND = forced if forced in ("torch", "rembg") else ("torch" if _torch_ok() else "rembg")
        print(f"sticker: backend = {_BACKEND}", file=sys.stderr)
    return _BACKEND


def _session():
    """Load the BiRefNet session once and keep it resident (avoids ~1GB reload/request).

    Defaults to CPU. CoreML EP is opt-in via KIDA_STICKER_PROVIDERS (e.g.
    "CoreMLExecutionProvider,CPUExecutionProvider") — measured a net loss here: heavy
    one-time graph compile on the first request for only ~1.3x steady-state. Falls back
    to the default provider if the requested ones fail.
    """
    global _SESSION
    if _SESSION is None:
        from rembg import new_session
        model = os.environ.get("KIDA_STICKER_MODEL", "birefnet-general-lite")
        providers = [
            p.strip() for p in os.environ.get(
                "KIDA_STICKER_PROVIDERS", "CPUExecutionProvider"
            ).split(",") if p.strip()
        ]
        try:
            _SESSION = new_session(model, providers=providers)
        except Exception as error:
            print(f"sticker: providers {providers} unavailable ({error}); using default", file=sys.stderr)
            _SESSION = new_session(model)
    return _SESSION


def _torch_model():
    """Load full BiRefNet once, on the Apple GPU (MPS) if available. Resident (model, device)."""
    global _TORCH_MODEL
    if _TORCH_MODEL is None:
        import torch
        from transformers import AutoModelForImageSegmentation
        repo = os.environ.get("KIDA_STICKER_TORCH_MODEL", "ZhengPeng7/BiRefNet")
        # checkpoint ships fp16 -> .float() to match the fp32 input
        model = AutoModelForImageSegmentation.from_pretrained(repo, trust_remote_code=True).eval().float()
        device = "mps" if torch.backends.mps.is_available() else ("cuda" if torch.cuda.is_available() else "cpu")
        _TORCH_MODEL = (model.to(device), device)
    return _TORCH_MODEL


def _torch_matte(image):
    """Return an L-mode alpha mask for `image` (PIL RGB) via BiRefNet on the GPU."""
    import numpy as np
    import torch
    from PIL import Image
    model, device = _torch_model()
    mean, std = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)
    arr = np.asarray(image.convert("RGB").resize((1024, 1024), Image.BILINEAR), dtype=np.float32) / 255.0
    for c in range(3):
        arr[:, :, c] = (arr[:, :, c] - mean[c]) / std[c]
    x = torch.from_numpy(arr.transpose(2, 0, 1)[None]).to(device)
    with torch.no_grad():
        y = model(x)
        if hasattr(y, "logits"):
            y = y.logits
        if isinstance(y, (list, tuple)):
            y = y[-1]
        prob = y.sigmoid()[0, 0].float().cpu().numpy()
    prob = (prob - prob.min()) / (prob.max() - prob.min() + 1e-8)
    return Image.fromarray((prob * 255).astype("uint8"), "L").resize(image.size, Image.LANCZOS)


def _cutout_rgba(image):
    """RGBA cutout of the salient object: torch-MPS BiRefNet if selected, else rembg (CPU)."""
    if _backend() == "torch":
        try:
            rgba = image.convert("RGBA")
            rgba.putalpha(_torch_matte(image))
            return rgba
        except Exception as error:
            print(f"sticker: torch backend failed ({error}); trying rembg", file=sys.stderr)
    from rembg import remove
    return remove(image, session=_session(), post_process_mask=True).convert("RGBA")


def warm_up() -> bool:
    """Optionally pre-load the model at server start (warms the selected backend)."""
    if not available():
        return False
    _torch_model() if _backend() == "torch" else _session()
    return True


def make_sticker(
    image_bytes: bytes,
    max_side: int = 1024,
    outline: bool = True,
    outline_px: int | None = None,
) -> tuple[bytes, tuple[int, int]]:
    """Return (PNG bytes, (width, height)) for the die-cut sticker.

    The image is downscaled to `max_side` for speed, matted with BiRefNet, given a white
    outline, and tight-cropped to the object. Results are cached by image hash.
    """
    key = f"{hashlib.sha256(image_bytes).hexdigest()}:{max_side}:{outline}:{outline_px}"
    if key in _CACHE:
        _CACHE.move_to_end(key)
        return _CACHE[key]

    from PIL import Image

    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    if max(image.size) > max_side:
        image.thumbnail((max_side, max_side), Image.LANCZOS)

    cutout = _cutout_rgba(image)
    if outline:
        cutout = _add_white_outline(cutout, outline_px)

    box = cutout.getbbox()
    if box:
        cutout = cutout.crop(box)

    buffer = io.BytesIO()
    cutout.save(buffer, format="PNG")

    result = (buffer.getvalue(), cutout.size)
    _CACHE[key] = result
    if len(_CACHE) > _CACHE_MAX:
        _CACHE.popitem(last=False)
    return result


def _add_white_outline(cutout, outline_px: int | None):
    """Dilate the alpha into a white silhouette behind the object (the sticker border)."""
    from PIL import Image, ImageFilter

    alpha = cutout.split()[-1]
    width, height = cutout.size
    radius = outline_px or max(3, min(width, height) // 90)
    kernel = radius * 2 + 1
    dilated = alpha.filter(ImageFilter.MaxFilter(kernel))

    sticker = Image.new("RGBA", cutout.size, (255, 255, 255, 0))
    solid_white = Image.new("RGBA", cutout.size, (255, 255, 255, 255))
    sticker.paste(solid_white, (0, 0), dilated)  # white where the dilated alpha is set
    sticker.alpha_composite(cutout)               # object on top
    return sticker
