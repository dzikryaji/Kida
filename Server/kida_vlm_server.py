#!/usr/bin/env python3
"""Local Kida VLM + RAG server.

The server is intentionally dependency-free so it can run on the Mac right away.
Set KIDA_FASTVLM_COMMAND later to call an Apple FastVLM runner that prints JSON.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
FACTS_PATH = ROOT / "object_facts.json"


def normalize_label(identifier: str) -> str:
    lowercased = (identifier or "object").lower().replace("_", " ").strip()
    aliases = [
        (["coffee mug", "mug", "cup", "teacup", "goblet"], "cup"),
        (["water bottle", "bottle", "flask"], "bottle"),
        (["book", "notebook", "binder", "comic book"], "book"),
        (["chair", "seat", "stool"], "chair"),
        (["potted plant", "houseplant", "plant", "flowerpot"], "plant"),
        (["backpack", "bag", "handbag", "purse"], "bag"),
        (["toy", "doll", "teddy", "figurine", "plush"], "toy"),
        (["table", "desk"], "table"),
        (["laptop", "computer", "notebook computer"], "laptop"),
        (["phone", "mobile phone", "cellular telephone", "smartphone"], "phone"),
        (["pen", "pencil", "marker"], "pen"),
    ]
    for keywords, label in aliases:
        if any(keyword in lowercased for keyword in keywords):
            return label
    return lowercased.split(",")[0].strip() or "object"


def load_fact_entries() -> list[dict[str, Any]]:
    with FACTS_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


FACT_ENTRIES = load_fact_entries()


def _sticker_backend_available() -> bool:
    try:
        import sticker_service
        return sticker_service.available()
    except Exception:
        return False


def score_fact_entry(entry: dict[str, Any], label_candidates: list[str]) -> int:
    terms = {normalize_label(entry.get("label", ""))}
    terms.update(normalize_label(alias) for alias in entry.get("aliases", []))
    score = 0
    for candidate in label_candidates:
        normalized = normalize_label(candidate)
        if normalized in terms or any(normalized in term or term in normalized for term in terms):
            score += 4
    return score


def retrieve_facts(label_candidates: list[str], limit: int = 6) -> dict[str, Any]:
    ranked = sorted(
        ((score_fact_entry(entry, label_candidates), entry) for entry in FACT_ENTRIES),
        key=lambda item: item[0],
        reverse=True,
    )
    selected = next((entry for score, entry in ranked if score > 0), None)
    if not selected:
        label = normalize_label(label_candidates[0] if label_candidates else "object")
        return {
            "label": label,
            "facts": [
                "Every object has a shape, a material, and a job.",
                "Looking closely can reveal color, texture, parts, and clues.",
            ],
            "safetyNotes": [
                "Avoid telling a child to taste, open, climb, or use unknown objects without an adult."
            ],
            "suggestedQuestions": [
                "What are you?",
                "What are you made of?",
                "What do you do?",
            ],
        }

    return {
        "label": selected["label"],
        "facts": selected.get("facts", [])[:limit],
        "safetyNotes": selected.get("safetyNotes", []),
        "suggestedQuestions": selected.get("suggestedQuestions", [])[:4],
    }


def extract_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    match = re.search(r"\{.*\}", stripped, flags=re.DOTALL)
    if not match:
        raise ValueError("FastVLM output did not contain a JSON object")
    return json.loads(match.group(0))


def build_prompt(detector: dict[str, Any]) -> str:
    alternatives = detector.get("alternatives") or []
    # NOTE: we intentionally do NOT feed a numeric normalized box. A 3B VLM does not
    # reliably obey in-prompt boxes, and the previous "origin is bottom-left" claim was
    # unverified against the client's coordinate convention. Target the object the child
    # framed (roughly centered / largest foreground object) qualitatively instead.
    return f"""
You are Kida's careful visual identifier for a young child's learning app.
Identify only the single main object the child framed — the large object near the center of the image. Ignore background and objects at the edges.
Reply with ONE JSON object and nothing else: no prose, no markdown, no comments, no thinking.
Describe only what you can clearly see. Never identify people. Never guess brand names or logos. Never invent text, numbers, or hidden parts. If you cannot clearly read text, return an empty readableText list — never guess letters.
If you are unsure what the object is, set uncertainty to "high" and lower confidence; being unsure is safer than being wrong.

Detector hint (a guess from an on-device detector — verify it against what you see, do not just repeat it):
- label: {detector.get("label", "object")}
- confidence: {detector.get("confidence", 0)}
- alternatives: {", ".join(alternatives) if alternatives else "none"}

Return JSON with exactly these keys:
{{
  "primaryLabel": "one common lowercase noun for the target object",
  "confidence": 0.0,
  "visualSummary": "one short factual sentence describing the target object's visible color, shape, material or parts",
  "colors": ["dominant visible colors of the target object only"],
  "material": "likely visible material such as plastic, metal, glass, paper, wood, fabric, ceramic, plant material, or null",
  "shape": "simple visible shape such as round, rectangular, cylindrical, flat, boxy, soft, tall, thin, or null",
  "readableText": ["visible words, letters, numbers, or symbols on the target object only"],
  "likelyUses": ["safe everyday functions of this object, based on the object type and visible clues"],
  "safetyNotes": ["child-safety caveats only if relevant to this object"],
  "uncertainty": "low, medium, or high"
}}

Field rules:
- primaryLabel must identify the target object, not the background.
- confidence should be lower if the focus area is blurry, partially hidden, or ambiguous.
- visualSummary should be concrete: color + shape/material/parts + object noun.
- colors, readableText, likelyUses, and safetyNotes must each have at most 4 items.
- readableText must be [] if no text is clearly readable.
- material and shape may be null if not visually supported.
- likelyUses should describe function, not personality.
- safetyNotes should be [] when there is no clear child-safety issue.
- Do not identify people. Do not guess brand names. Do not invent hidden parts.
- Use simple labels such as bottle, cup, book, plant, toy, chair, table, bag, phone, laptop, pen, or object when appropriate.
""".strip()


def run_fastvlm(image_bytes: bytes, detector: dict[str, Any], timeout: float) -> dict[str, Any] | None:
    raw_command = os.environ.get("KIDA_FASTVLM_COMMAND", "").strip()
    if not raw_command:
        return None

    prompt = build_prompt(detector)
    with tempfile.TemporaryDirectory(prefix="kida-fastvlm-") as temp_dir:
        temp_path = Path(temp_dir)
        image_path = temp_path / "object.jpg"
        prompt_path = temp_path / "prompt.txt"
        image_path.write_bytes(image_bytes)
        prompt_path.write_text(prompt, encoding="utf-8")

        command_parts = shlex.split(raw_command)
        formatted = [
            part.format(image=str(image_path), prompt=str(prompt_path))
            for part in command_parts
        ]
        if "{image}" not in raw_command:
            formatted.append(str(image_path))
        if "{prompt}" not in raw_command:
            formatted.extend(["--prompt", str(prompt_path)])

        completed = subprocess.run(
            formatted,
            capture_output=True,
            check=False,
            text=True,
            timeout=timeout,
        )
        if completed.returncode != 0:
            output = "\n".join(
                part.strip()
                for part in [completed.stdout, completed.stderr]
                if part.strip()
            )
            raise RuntimeError(
                f"VLM command exited {completed.returncode}: {output[:1200]}"
            )

    output = completed.stdout.strip()
    if not output:
        raise ValueError("FastVLM command returned empty output")
    parsed = extract_json_object(output)
    return parsed.get("objectIntelligence", parsed)


def fallback_card(detector: dict[str, Any]) -> dict[str, Any]:
    label = normalize_label(detector.get("label", "object"))
    confidence = float(detector.get("confidence") or 0)
    return {
        "primaryLabel": label,
        "confidence": confidence,
        "visualSummary": f"The local detector thinks this is a {label}.",
        "colors": [],
        "material": None,
        "shape": None,
        "readableText": [],
        "likelyUses": [],
        "safetyNotes": [],
        "uncertainty": "high" if confidence < 0.45 else "medium",
    }


def sanitized_card(card: dict[str, Any], detector: dict[str, Any]) -> dict[str, Any]:
    fallback = fallback_card(detector)
    merged = {**fallback, **(card or {})}
    merged["primaryLabel"] = normalize_label(str(merged.get("primaryLabel") or fallback["primaryLabel"]))
    try:
        merged["confidence"] = float(merged.get("confidence", fallback["confidence"]))
    except (TypeError, ValueError):
        merged["confidence"] = fallback["confidence"]
    merged["confidence"] = max(0.0, min(1.0, merged["confidence"]))

    for key in ["colors", "readableText", "likelyUses", "safetyNotes"]:
        value = merged.get(key)
        if not isinstance(value, list):
            merged[key] = []
        else:
            items = [str(item).strip() for item in value if str(item).strip()]
            if key == "safetyNotes":
                items = [
                    item for item in items
                    if not re.match(r"(?i)^not\s+(a|an|the)\b", item)
                ]
            merged[key] = items[:4]

    for key in ["material", "shape", "uncertainty"]:
        value = merged.get(key)
        merged[key] = str(value).strip() if value not in (None, "") else None

    merged["visualSummary"] = str(merged.get("visualSummary") or fallback["visualSummary"]).strip()
    return merged


class KidaVLMHandler(BaseHTTPRequestHandler):
    server_version = "KidaVLM/0.1"
    token = ""
    fastvlm_timeout = 20.0

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(
                {
                    "ok": True,
                    "fastVLMConfigured": bool(os.environ.get("KIDA_FASTVLM_COMMAND", "").strip()),
                    "vlmSource": os.environ.get("KIDA_VLM_SOURCE", "local-vlm"),
                    "facts": len(FACT_ENTRIES),
                    "stickerBackend": _sticker_backend_available(),
                }
            )
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path not in ("/object/understand", "/object/sticker"):
            self.send_error(404)
            return

        if not self.authorized():
            self.send_json({"error": "unauthorized"}, status=401)
            return

        if self.path == "/object/sticker":
            self.handle_sticker()
            return

        try:
            request = self.read_json()
            image_payload = request.get("image") or {}
            detector = request.get("detector") or {}
            image_bytes = base64.b64decode(image_payload.get("data", ""), validate=True)
            if not image_bytes:
                raise ValueError("Missing image data")

            source = os.environ.get("KIDA_VLM_SOURCE", "local-vlm")
            try:
                card = run_fastvlm(image_bytes, detector, self.fastvlm_timeout)
            except Exception as error:  # Keep the app responsive if FastVLM is still being wired.
                print(f"FastVLM failed, using heuristic card: {error}", file=sys.stderr)
                card = None

            if card is None:
                source = "heuristic"
                card = fallback_card(detector)

            card = sanitized_card(card, detector)
            label_candidates = [
                card.get("primaryLabel", "object"),
                detector.get("label", "object"),
                *(detector.get("alternatives") or []),
            ]
            retrieved = retrieve_facts([str(label) for label in label_candidates])
            suggested = retrieved.pop("suggestedQuestions", [])

            self.send_json(
                {
                    "objectIntelligence": card,
                    "retrievedFacts": retrieved,
                    "suggestedQuestions": suggested,
                    "source": source,
                }
            )
        except Exception as error:
            self.send_json({"error": str(error)}, status=400)

    def handle_sticker(self) -> None:
        # BiRefNet sticker tier — optional, gated on the sticker extras being installed.
        try:
            import sticker_service
        except Exception as error:
            self.send_json({"error": f"sticker backend unavailable: {error}"}, status=501)
            return
        if not sticker_service.available():
            self.send_json(
                {"error": "sticker backend not installed (pip install -r Server/requirements-sticker.txt)"},
                status=501,
            )
            return

        try:
            request = self.read_json()
            image_bytes = base64.b64decode((request.get("image") or {}).get("data", ""), validate=True)
            if not image_bytes:
                raise ValueError("Missing image data")
            png, (width, height) = sticker_service.make_sticker(image_bytes)
            self.send_json(
                {
                    "sticker": {"mimeType": "image/png", "data": base64.b64encode(png).decode("ascii")},
                    "width": width,
                    "height": height,
                    "source": os.environ.get("KIDA_STICKER_MODEL", "birefnet-general-lite"),
                }
            )
        except Exception as error:
            self.send_json({"error": str(error)}, status=400)

    def authorized(self) -> bool:
        if not self.token:
            return True
        auth_header = self.headers.get("Authorization", "")
        token_header = self.headers.get("X-Kida-Token", "")
        return auth_header == f"Bearer {self.token}" or token_header == self.token

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        return json.loads(body.decode("utf-8"))

    def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Kida's local Mac VLM + RAG server.")
    parser.add_argument("--host", default=os.environ.get("KIDA_VLM_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("KIDA_VLM_PORT", "8787")))
    parser.add_argument("--token", default=os.environ.get("KIDA_VLM_SERVER_TOKEN", ""))
    parser.add_argument(
        "--fastvlm-timeout",
        type=float,
        default=float(os.environ.get("KIDA_FASTVLM_TIMEOUT", "20")),
    )
    args = parser.parse_args()

    KidaVLMHandler.token = args.token.strip()
    KidaVLMHandler.fastvlm_timeout = args.fastvlm_timeout

    server = ThreadingHTTPServer((args.host, args.port), KidaVLMHandler)
    print(f"Kida VLM server listening on http://{args.host}:{args.port}")
    print(f"FastVLM command configured: {bool(os.environ.get('KIDA_FASTVLM_COMMAND', '').strip())}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Kida VLM server.")


if __name__ == "__main__":
    main()
