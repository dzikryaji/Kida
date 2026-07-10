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
import tempfile
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps


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
    parser.add_argument("--image-max-edge", type=int, default=int(os.environ.get("KIDA_MLX_IMAGE_MAX_EDGE", "1280")))
    parser.add_argument(
        "--thinking-mode",
        choices=("enabled", "disabled", "adaptive"),
        default=os.environ.get("KIDA_MLX_THINKING_MODE"),
        help="Pass through to newer mlx-vlm chat templates. Defaults to disabled for Qwen3-VL.",
    )
    return parser.parse_args()


def run_mlx_generate(args: argparse.Namespace) -> str:
    if not args.model:
        raise SystemExit("Missing --model or KIDA_MLX_VLM_MODEL.")

    prompt = Path(args.prompt_file).read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="kida-mlx-vlm-") as temp_dir:
        image_path = prepare_image_for_mlx(args.image, Path(temp_dir), args.image_max_edge)
        command = [
            sys.executable,
            "-m",
            "mlx_vlm.generate",
            "--model",
            args.model,
            "--image",
            image_path,
            "--prompt",
            prompt,
            "--max-tokens",
            str(args.max_tokens),
            "--temperature",
            str(args.temp),
            "--no-verbose",
        ]
        thinking_mode = args.thinking_mode
        if thinking_mode is None and "qwen3-vl" in args.model.lower():
            thinking_mode = "disabled"
        if thinking_mode:
            command.extend(["--thinking-mode", thinking_mode])

        completed = run_command(command)
        if completed.returncode == 0:
            return completed.stdout

        combined = f"{completed.stdout}\n{completed.stderr}"
        unsupported_flags = ["--thinking-mode", "--no-verbose"]
        for unsupported in unsupported_flags:
            if unsupported in combined and "unrecognized" in combined.lower():
                retry_command = remove_flag(command, unsupported, has_value=unsupported == "--thinking-mode")
                completed = run_command(retry_command)
                if completed.returncode == 0:
                    return completed.stdout
                command = retry_command
                combined = f"{completed.stdout}\n{completed.stderr}"

        if "--temperature" in combined and "unrecognized" in combined.lower():
            retry_command = remove_flag(command, "--temperature", has_value=True)
            retry_command.extend(["--temp", str(args.temp)])
            completed = run_command(retry_command)
            if completed.returncode == 0:
                return completed.stdout
            combined = f"{completed.stdout}\n{completed.stderr}"

        raise RuntimeError(combined.strip() or "mlx-vlm failed without output.")


def prepare_image_for_mlx(image_path: str, temp_dir: Path, max_edge: int) -> str:
    if max_edge <= 0:
        return image_path

    image = Image.open(image_path)
    image = ImageOps.exif_transpose(image).convert("RGB")
    image.thumbnail((max_edge, max_edge), Image.Resampling.LANCZOS)

    prepared_path = temp_dir / "image.jpg"
    image.save(prepared_path, "JPEG", quality=92, optimize=True)
    return str(prepared_path)


def remove_flag(command: list[str], flag: str, has_value: bool) -> list[str]:
    cleaned: list[str] = []
    skip_next = False
    for part in command:
        if skip_next:
            skip_next = False
            continue
        if part == flag:
            skip_next = has_value
            continue
        cleaned.append(part)
    return cleaned


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
        "characterName",
        "confidence",
        "visualSummary",
        "childDescription",
        "functionality",
        "colors",
        "material",
        "shape",
        "brand",
        "readableText",
        "likelyUses",
        "safetyNotes",
        "riskLevel",
        "riskReason",
        "uncertainty",
        "personality",
        "emotion",
        "voiceGender",
        "voiceFamily",
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
            "characterName": None,
            "confidence": 0.55 if label != "object" else 0.35,
            "visualSummary": summary,
            "childDescription": None,
            "functionality": None,
            "colors": [],
            "material": None,
            "shape": None,
            "brand": None,
            "readableText": [],
            "likelyUses": [],
            "safetyNotes": [],
            "riskLevel": "none",
            "riskReason": None,
            "uncertainty": "medium" if label != "object" else "high",
            "personality": None,
            "emotion": None,
            "voiceGender": None,
            "voiceFamily": None,
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
        "characterName": clean_optional(card.get("characterName") or card.get("character_name")),
        "confidence": confidence,
        "visualSummary": visual_summary,
        "childDescription": clean_optional(card.get("childDescription") or card.get("child_description")),
        "functionality": clean_optional(card.get("functionality")),
        "colors": clean_list(card.get("colors")),
        "material": clean_optional(card.get("material")),
        "shape": clean_optional(card.get("shape")),
        "brand": clean_optional(card.get("brand")),
        "readableText": clean_list(card.get("readableText") or card.get("readable_text")),
        "likelyUses": clean_list(card.get("likelyUses") or card.get("likely_uses")),
        "safetyNotes": clean_list(card.get("safetyNotes") or card.get("safety_notes")),
        "riskLevel": clean_optional(card.get("riskLevel") or card.get("risk_level")),
        "riskReason": clean_optional(card.get("riskReason") or card.get("risk_reason")),
        "uncertainty": clean_optional(card.get("uncertainty")) or "medium",
        "personality": clean_optional(card.get("personality")),
        "emotion": clean_optional(card.get("emotion")),
        "voiceGender": clean_optional(card.get("voiceGender") or card.get("voice_gender")),
        "voiceFamily": clean_optional(card.get("voiceFamily") or card.get("voice_family")),
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
