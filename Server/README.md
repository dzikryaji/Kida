# Kida Mac VLM Server

This local server lets the iPhone app use your Mac as the object-understanding box:

```text
iPhone full frame + focus hint -> Mac VLM eyes + local/Tavily RAG -> ObjectIntelligenceCard + facts -> iPhone FoundationModels
```

The server runs with Python standard library only. It returns Mac-side RAG facts immediately. If `KIDA_FASTVLM_COMMAND` is set, it calls that command for Apple FastVLM-style vision output.

## Run

```sh
python3 Server/kida_vlm_server.py --host 0.0.0.0 --port 8787 --token local-dev-token
```

Find your Mac's local IP:

```sh
ipconfig getifaddr en0
```

Then add this to `Supporting/Secrets.xcconfig`:

```xcconfig
VLM_SERVER_URL = http:/$()/YOUR_MAC_IP:8787
VLM_SERVER_TOKEN = local-dev-token
VLM_SERVER_TIMEOUT = 5
```

The `/$()/` piece is intentional. Plain `http://` is parsed as a comment in
`.xcconfig` files, which turns the URL into `http:`.

If `VLM_SERVER_URL` is not set or the server fails, the iPhone app uses local facts without cloud VLM fallback.

## Health Check

```sh
curl http://127.0.0.1:8787/health
```

Expected:

```json
{"ok": true, "fastVLMConfigured": false, "facts": 11, "tavilyConfigured": false}
```

## Tavily fact enrichment (optional)

Qwen should focus on being the eyes: label, visible color/shape/material, readable text,
and visible brand. The server can then enrich the object once at scan time with kid-safe
web facts from Tavily. Keep the Tavily key on the Mac/server, not in the iOS app:

```sh
export TAVILY_API_KEY=tvly-YOUR_KEY
bash Server/run_mlx_server.sh
```

Or put it in a local secret file that is loaded by the launcher:

```sh
cp Server/.env.example Server/.env
# edit Server/.env and set TAVILY_API_KEY
bash Server/run_mlx_server.sh
```

`Server/.env`, `Server/.env.local`, and `Server/secrets.env` are gitignored.
For convenience, the launcher also reads `TAVILY_API_KEY` from
`Supporting/Secrets.xcconfig` if you already keep dev secrets there, but the iOS app
does not need this key.

When configured, `/object/understand` merges Tavily facts with local facts and the response
`source` includes `+tavily`. Dangerous objects skip Tavily enrichment and stay on local
safety facts.

## Sticker tier (BiRefNet, optional)

`POST /object/sticker` turns a photo into a clean die-cut sticker (transparent PNG + white
outline) using BiRefNet automatic matting — the "better when home" tier. It's off by default
so the base server stays dependency-free. Enable it:

```sh
.venv/bin/python -m pip install -r Server/requirements-sticker.txt   # rembg + onnxruntime
```

Model is chosen via `KIDA_STICKER_MODEL` (default `birefnet-general-lite` for ~1-2 s;
use `birefnet-general` for best quality but ~10 s+). Request/response:

The server warms the sticker backend in the background on startup so the first Save does
not pay the model-load cost. Set `KIDA_STICKER_WARMUP=0` to disable this.

```jsonc
// POST /object/sticker   { "image": { "mimeType": "image/jpeg", "data": "<base64>" } }
// -> { "sticker": { "mimeType": "image/png", "data": "<base64>" }, "width": W, "height": H }
```

The iOS `StickerService` calls this when the Mac is reachable and falls back to on-device
SAM 2 otherwise. `/health` reports `stickerBackend: true|false`.

## FastVLM Hook

Point `KIDA_FASTVLM_COMMAND` at a command that accepts an image and prompt file, then prints JSON for `ObjectIntelligenceCard`.

For a project-local MLX setup:

```sh
cd /Users/andrian/Work/Apple/kida
python3 -m venv .venv
.venv/bin/python -m pip install -r Server/requirements-mlx.txt
bash Server/run_mlx_server.sh
```

By default the launcher uses `mlx-community/Qwen3-VL-4B-Instruct-3bit` for
stronger object-card accuracy while still fitting on Apple Silicon. Set
`KIDA_MLX_VLM_MODEL=mlx-community/Qwen2.5-VL-3B-Instruct-4bit` to run the older
Qwen2.5 path.
To use an exported Apple FastVLM model instead:

```sh
bash Server/download_fastvlm_model.sh 0.5b
KIDA_MLX_PYTHON=.venv-fastvlm/bin/python KIDA_MLX_VLM_MODEL=Server/fastvlm-0.5b KIDA_VLM_SOURCE=apple-fastvlm bash Server/run_mlx_server.sh
```

After the patched FastVLM environment is installed, the shorter launcher is:

```sh
bash Server/run_fastvlm_server.sh
```

To try SmolVLM through the same server:

```sh
.venv/bin/python -m pip install -r Server/requirements-smolvlm.txt
bash Server/run_smolvlm_server.sh
```

The default SmolVLM launcher uses `mlx-community/SmolVLM2-500M-Video-Instruct-mlx`.
It is lighter than the bigger VLMs, but it benefits a lot from the detector hint
and the focus region.

Example shape:

```sh
export KIDA_FASTVLM_COMMAND='.venv/bin/python Server/mlx_vlm_runner.py --model /path/to/exported-fastvlm --image {image} --prompt-file {prompt}'
python3 Server/kida_vlm_server.py --host 0.0.0.0 --port 8787 --token local-dev-token
```

The command should print either:

```json
{
  "primaryLabel": "bottle",
  "characterName": "Sip Scout",
  "confidence": 0.82,
  "visualSummary": "blue plastic bottle with a cap",
  "colors": ["blue"],
  "material": "plastic",
  "shape": "tall cylinder",
  "readableText": [],
  "likelyUses": ["holding drinks"],
  "safetyNotes": ["do not drink unknown liquids"],
  "uncertainty": "low"
}
```

or:

```json
{
  "objectIntelligence": {
    "primaryLabel": "bottle",
    "characterName": "Sip Scout",
    "confidence": 0.82,
    "visualSummary": "blue plastic bottle with a cap",
    "colors": ["blue"],
    "material": "plastic",
    "shape": "tall cylinder",
    "readableText": [],
    "likelyUses": ["holding drinks"],
    "safetyNotes": ["do not drink unknown liquids"],
    "uncertainty": "low"
  }
}
```

## Endpoint

`POST /object/understand`

Input:

```json
{
  "image": {
    "mimeType": "image/jpeg",
    "data": "base64..."
  },
  "detector": {
    "label": "bottle",
    "confidence": 0.42,
    "alternatives": ["cup"],
    "visualContext": "Detected object: bottle"
  }
}
```

Output:

```json
{
  "objectIntelligence": {
    "primaryLabel": "bottle",
    "characterName": "Sip Scout",
    "confidence": 0.42,
    "visualSummary": "The local detector thinks this is a bottle.",
    "colors": [],
    "material": null,
    "shape": null,
    "readableText": [],
    "likelyUses": [],
    "safetyNotes": [],
    "uncertainty": "high"
  },
  "retrievedFacts": {
    "label": "bottle",
    "facts": ["Bottles hold liquids so people can carry drinks."],
    "safetyNotes": ["Do not suggest drinking unknown liquids."]
  },
  "suggestedQuestions": ["Why do you have a cap?"],
  "source": "heuristic"
}
```
