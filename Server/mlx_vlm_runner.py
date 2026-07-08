#!/usr/bin/env python3
"""Run an MLX VLM model and normalize its answer for Kida.

The Kida server passes a camera frame and prompt file to this script through
KIDA_FASTVLM_COMMAND. The script prints only ObjectIntelligenceCard JSON.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


KNOWN_LABELS = [
    "bottle",
    "cup",
    "book",
    "plant",
    "toy",
    "chair",
    "table",
    "bag",
    "phone",
    "laptop",
    "pen",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run mlx-vlm and emit Kida object JSON.")
    parser.add_argument("--model", default=os.environ.get("KIDA_MLX_VLM_MODEL", ""))
    parser.add_argument("--image", required=True)
    parser.add_argument("--prompt-file", "--prompt", dest="prompt_file", required=True)
    parser.add_argument("--max-tokens", type=int, default=int(os.environ.get("KIDA_MLX_MAX_TOKENS", "384")))
    parser.add_argument("--temp", type=float, default=float(os.environ.get("KIDA_MLX_TEMP", "0.0")))
    return parser.parse_args()


def run_mlx_generate(args: argparse.Namespace) -> str:
    if not args.model:
        raise SystemExit("Missing --model or KIDA_MLX_VLM_MODEL.")

    prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    command = [
        sys.executable,
        "-m",
        "mlx_vlm.generate",
        "--model",
        args.model,
        "--image",
        args.image,
        "--prompt",
        prompt,
        "--max-tokens",
        str(args.max_tokens),
        "--temperature",
        str(args.temp),
        "--no-verbose",
    ]

    completed = run_command(command)
    if completed.returncode == 0:
        return completed.stdout

    combined = f"{completed.stdout}\n{completed.stderr}"
    if "--no-verbose" in combined and "unrecognized" in combined.lower():
        retry_command = [part for part in command if part != "--no-verbose"]
        completed = run_command(retry_command)
        if completed.returncode == 0:
            return completed.stdout
        combined = f"{completed.stdout}\n{completed.stderr}"

    if "--temp" in combined and "unrecognized" in combined.lower():
        retry_command = command[:-2] + ["--temperature", str(args.temp)]
        completed = run_command(retry_command)
        if completed.returncode == 0:
            return completed.stdout
        combined = f"{completed.stdout}\n{completed.stderr}"

    raise RuntimeError(combined.strip() or "mlx-vlm failed without output.")


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        capture_output=True,
        check=False,
        text=True,
    )


def candidate_json_objects(text: str) -> list[dict[str, Any]]:
    decoder = json.JSONDecoder()
    candidates: list[dict[str, Any]] = []
    for match in re.finditer(r"\{", text):
        try:
            parsed, _ = decoder.raw_decode(text[match.start():])
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            candidates.append(parsed)
    return candidates


def extract_card(text: str) -> dict[str, Any]:
    cleaned_text = strip_markdown_fences(text)
    for candidate in reversed(candidate_json_objects(text)):
        if isinstance(candidate.get("objectIntelligence"), dict):
            return sanitize_card(candidate["objectIntelligence"], text)
        if "primaryLabel" in candidate or "visualSummary" in candidate:
            return sanitize_card(candidate, text)

    partial_card = extract_partial_card(cleaned_text)
    if partial_card:
        return sanitize_card(partial_card, text)

    return summarize_text_output(text)


def strip_markdown_fences(text: str) -> str:
    return re.sub(r"```(?:json)?|```", "", text, flags=re.IGNORECASE).strip()


def extract_partial_card(text: str) -> dict[str, Any] | None:
    keys = [
        "primaryLabel",
        "confidence",
        "visualSummary",
        "colors",
        "material",
        "shape",
        "readableText",
        "likelyUses",
        "safetyNotes",
        "uncertainty",
    ]
    card: dict[str, Any] = {}
    for key in keys:
        value = extract_partial_value(text, key)
        if value is not None:
            card[key] = value

    return card if "primaryLabel" in card or "visualSummary" in card else None


def extract_partial_value(text: str, key: str) -> Any:
    array_match = re.search(rf'"{re.escape(key)}"\s*:\s*(\[[^\]]*\])', text, flags=re.DOTALL)
    if array_match:
        try:
            return json.loads(array_match.group(1))
        except json.JSONDecodeError:
            return [
                item.strip().strip('"').strip("'")
                for item in array_match.group(1).strip("[]").split(",")
                if item.strip().strip('"').strip("'")
            ]

    string_match = re.search(rf'"{re.escape(key)}"\s*:\s*"([^"]*)', text, flags=re.DOTALL)
    if string_match:
        return string_match.group(1).strip()

    number_match = re.search(rf'"{re.escape(key)}"\s*:\s*([0-9]+(?:\.[0-9]+)?)', text)
    if number_match:
        return number_match.group(1)

    null_match = re.search(rf'"{re.escape(key)}"\s*:\s*null\b', text)
    if null_match:
        return None

    return None


def summarize_text_output(text: str) -> dict[str, Any]:
    cleaned = " ".join(text.strip().split())
    label = "object"
    lowered = cleaned.lower()
    for candidate in KNOWN_LABELS:
        if re.search(rf"\b{re.escape(candidate)}\b", lowered):
            label = candidate
            break

    summary = cleaned
    if len(summary) > 180:
        summary = summary[:177].rstrip() + "..."
    if not summary:
        summary = "The MLX vision model did not return a description."

    return sanitize_card(
        {
            "primaryLabel": label,
            "confidence": 0.55 if label != "object" else 0.35,
            "visualSummary": summary,
            "colors": [],
            "material": None,
            "shape": None,
            "readableText": [],
            "likelyUses": [],
            "safetyNotes": [],
            "uncertainty": "medium" if label != "object" else "high",
        },
        text,
    )


def sanitize_card(card: dict[str, Any], raw_text: str) -> dict[str, Any]:
    primary_label = str(card.get("primaryLabel") or card.get("label") or "object").lower().strip()
    primary_label = re.sub(r"[^a-z0-9 _-]+", "", primary_label).replace("_", " ").strip() or "object"
    if "," in primary_label:
        primary_label = primary_label.split(",", 1)[0].strip() or "object"

    try:
        confidence = float(card.get("confidence", 0.5))
    except (TypeError, ValueError):
        confidence = 0.5
    confidence = max(0.0, min(1.0, confidence))

    visual_summary = str(card.get("visualSummary") or card.get("summary") or "").strip()
    if not visual_summary:
        visual_summary = summarize_text_output(raw_text)["visualSummary"] if raw_text.strip() else "No visual summary available."

    return {
        "primaryLabel": primary_label,
        "confidence": confidence,
        "visualSummary": visual_summary,
        "colors": clean_list(card.get("colors")),
        "material": clean_optional(card.get("material")),
        "shape": clean_optional(card.get("shape")),
        "readableText": clean_list(card.get("readableText") or card.get("readable_text")),
        "likelyUses": clean_list(card.get("likelyUses") or card.get("likely_uses")),
        "safetyNotes": clean_list(card.get("safetyNotes") or card.get("safety_notes")),
        "uncertainty": clean_optional(card.get("uncertainty")) or "medium",
    }


def clean_list(value: Any) -> list[str]:
    if isinstance(value, str):
        values = split_list_text(value)
    elif isinstance(value, list):
        values = [str(item).strip() for item in value if str(item).strip()]
    else:
        return []

    cleaned: list[str] = []
    seen: set[str] = set()
    for item in values:
        shortened = item[:140].rstrip()
        key = shortened.lower()
        if shortened and key not in seen:
            cleaned.append(shortened)
            seen.add(key)
        if len(cleaned) >= 4:
            break

    return cleaned


def split_list_text(value: str) -> list[str]:
    cleaned = value.strip()
    if not cleaned:
        return []
    if "," in cleaned or ";" in cleaned:
        return [part.strip() for part in re.split(r"[,;]", cleaned) if part.strip()]
    return [cleaned]


def clean_optional(value: Any) -> str | None:
    if value is None:
        return None
    cleaned = str(value).strip()
    if not cleaned or cleaned.lower() == "null":
        return None
    return cleaned


def main() -> None:
    args = parse_args()
    output = run_mlx_generate(args)
    card = extract_card(output)
    print(json.dumps(card, ensure_ascii=False))


if __name__ == "__main__":
    main()
