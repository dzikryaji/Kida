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
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
FACTS_PATH = ROOT / "object_facts.json"


def normalize_label(identifier: str) -> str:
    lowercased = (identifier or "object").lower().replace("_", " ").strip()
    aliases = [
        (["perfume bottle", "cologne bottle"], "perfume bottle"),
        (["medicine bottle", "pill bottle"], "medicine bottle"),
        (["baby bottle"], "baby bottle"),
        (["tissue box"], "tissue box"),
        (["wine glass", "champagne glass"], "wine glass"),
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

PERSONALITIES = {"boss", "cool", "fancy", "sweet", "cautious"}
EMOTIONS = {"happy", "sad", "angry"}
VOICE_GENDERS = {"man", "woman"}
VOICE_FAMILIES = {"bright", "gentle", "confident", "careful"}
TAVILY_ENDPOINT = "https://api.tavily.com/search"
TAVILY_TIMEOUT = float(os.environ.get("KIDA_TAVILY_TIMEOUT", "8"))
TAVILY_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
TAVILY_CACHE_TTL = float(os.environ.get("KIDA_TAVILY_CACHE_TTL", "86400"))

DANGER_WORDS = [
    "knife", "scissor", "blade", "razor", "stove", "oven", "heater", "outlet",
    "socket", "plug", "cord", "battery", "lighter", "match", "candle", "flame",
    "medicine", "pill", "syringe", "needle", "chemical", "cleaner", "bleach", "sharp",
]
COOL_WORDS = [
    "ball", "skateboard", "sneaker", "shoe", "headphone", "earbud", "sunglass",
    "bicycle", "bike", "scooter", "controller", "sport", "guitar", "cap",
    "game", "toy car", "frisbee",
]
SWEET_WORDS = [
    "pillow", "blanket", "plush", "stuffed", "teddy", "doll", "toy", "teapot",
    "tissue", "tissue box", "cushion", "mug", "flower", "bear", "bunny", "baby",
    "baby bottle", "soft",
]
FANCY_WORDS = [
    "perfume", "wine", "champagne", "vase", "frame", "jewel", "ring", "necklace",
    "crystal", "trophy", "medal", "bow tie", "watch", "photo", "glassware",
    "tableware", "decorative",
]
BOSS_WORDS = [
    "money", "cash", "wallet", "credit card", "coin", "safe", "piggy", "remote",
    "key", "calculator", "book", "clock", "phone", "laptop", "computer", "tablet",
    "badge", "card",
]
UNSAFE_FACT_WORDS = [
    "kill", "murder", "stab", "shoot", "weapon", "bomb", "blood", "suicide",
    "sex", "naked", "drug", "alcohol", "beer", "wine", "cigarette", "vape",
    "password", "credit card", "phone number", "address", "politics",
]
SHOPPING_WORDS = [
    "buy", "shop", "sale", "discount", "price", "coupon", "subscribe",
    "affiliate", "amazon", "cart", "checkout",
]


def _sticker_backend_available() -> bool:
    try:
        import sticker_service
        return sticker_service.available()
    except Exception:
        return False


def contains_any(text: str, words: list[str]) -> bool:
    tokens = set(re.findall(r"[a-z0-9]+", text.lower()))
    for word in words:
        term = word.lower()
        if " " in term:
            if term in text:
                return True
            continue
        variants = {term, f"{term}s"}
        if term.endswith(("s", "x", "ch")):
            variants.add(f"{term}es")
        if term == "knife":
            variants.add("knives")
        if tokens.intersection(variants):
            return True
    return False


def is_dangerous(label: str, safety_notes: list[str] | None = None) -> bool:
    text = f"{label} {' '.join(safety_notes or [])}".lower()
    return contains_any(text, DANGER_WORDS)


def explicit_personality_for_label(label: str, safety_notes: list[str] | None = None) -> str | None:
    text = label.lower()
    if is_dangerous(label, safety_notes):
        return "cautious"
    if contains_any(text, BOSS_WORDS):
        return "boss"
    if contains_any(text, COOL_WORDS):
        return "cool"
    if contains_any(text, SWEET_WORDS):
        return "sweet"
    if contains_any(text, FANCY_WORDS):
        return "fancy"
    return None


def map_personality(label: str, safety_notes: list[str] | None = None) -> str:
    explicit = explicit_personality_for_label(label, safety_notes)
    if explicit:
        return explicit
    return "cool"


def default_emotion(personality: str) -> str:
    return "angry" if personality == "cautious" else "happy"


def voice_family_for_personality(personality: str) -> str:
    return {
        "boss": "confident",
        "cool": "bright",
        "fancy": "gentle",
        "sweet": "gentle",
        "cautious": "careful",
    }.get(personality, "bright")


def character_name_for(label: str, personality: str) -> str:
    normalized = normalize_label(label)
    names = {
        "laptop": "Captain Click",
        "phone": "Captain Ping",
        "book": "Professor Page",
        "bottle": "Sip Scout",
        "cup": "Cup Cozy",
        "plant": "Leafy Pal",
        "toy": "Giggle Buddy",
        "chair": "Comfy Captain",
        "table": "Tidy Table",
        "bag": "Pocket Pal",
        "pen": "Inky Spark",
    }
    if normalized in names:
        return names[normalized]
    display = " ".join(part.capitalize() for part in normalized.split())
    prefix = {
        "boss": "Captain",
        "cool": "Dash",
        "fancy": "Fancy",
        "sweet": "Cozy",
        "cautious": "Careful",
    }.get(personality, "Kida")
    return f"{prefix} {display}".strip()


def sanitize_character_name(value: Any, label: str, personality: str) -> str:
    fallback = character_name_for(label, personality)
    if not isinstance(value, str):
        return fallback
    cleaned = clean_text(value, limit=32)
    if not 2 <= len(cleaned) <= 28:
        return fallback
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 '-]{1,27}", cleaned):
        return fallback
    lower = cleaned.lower()
    blocked = ["kid", "child", "baby", "sexy", "kill", "stab", "gun", "blood", "password"]
    if any(term in lower for term in blocked):
        return fallback
    normalized = normalize_label(label)
    generic_names = {
        f"sunny {normalized}",
        f"happy {normalized}",
        f"friendly {normalized}",
        f"{normalized} friend",
        f"{normalized} buddy",
    }
    if lower in generic_names:
        return fallback
    words = cleaned.split()[:3]
    return " ".join(word[:1].upper() + word[1:].lower() for word in words)


def stable_voice_gender(label: str) -> str:
    seed = sum(ord(char) for char in label.lower())
    return "woman" if seed % 2 == 0 else "man"


def sanitize_choice(value: Any, allowed: set[str], fallback: str) -> str:
    if isinstance(value, str):
        candidate = value.strip().lower()
        if candidate in allowed:
            return candidate
    return fallback


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


def tavily_key() -> str:
    return (
        os.environ.get("KIDA_TAVILY_API_KEY")
        or os.environ.get("TAVILY_API_KEY")
        or ""
    ).strip()


def is_tavily_configured() -> bool:
    key = tavily_key()
    return bool(key and "$(" not in key)


def clean_text(value: Any, limit: int = 260) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    return text[:limit].strip()


def is_safe_fact_snippet(text: str) -> bool:
    lower = text.lower()
    if len(lower) < 18:
        return False
    if "http" in lower or "www." in lower:
        return False
    if any(word in lower for word in UNSAFE_FACT_WORDS):
        return False
    if any(word in lower for word in SHOPPING_WORDS):
        return False
    if lower.count("$") > 0:
        return False
    return True


def split_fact_candidates(text: str) -> list[str]:
    compact = clean_text(text, limit=1600)
    parts = re.split(r"(?<=[.!?])\s+", compact)
    return [clean_text(part.rstrip(".!?"), limit=180) for part in parts]


def tavily_query_for(card: dict[str, Any]) -> str:
    label = normalize_label(str(card.get("primaryLabel") or "object"))
    brand = clean_text(card.get("brand"), limit=60)
    visual_bits = [
        clean_text(card.get("material"), limit=50),
        clean_text(card.get("shape"), limit=50),
        ", ".join(card.get("colors") or []),
    ]
    visual = " ".join(bit for bit in visual_bits if bit)
    subject = " ".join(part for part in [brand, label, visual] if part).strip()
    return f"kid friendly educational facts about {subject} safe everyday use"


def tavily_retrieve_facts(card: dict[str, Any], limit: int = 4) -> dict[str, Any] | None:
    if not is_tavily_configured():
        return None

    label = normalize_label(str(card.get("primaryLabel") or "object"))
    if is_dangerous(label, card.get("safetyNotes", [])):
        return None

    query = tavily_query_for(card)
    cache_key = query.lower()
    cached = TAVILY_CACHE.get(cache_key)
    if cached and time.time() - cached[0] < TAVILY_CACHE_TTL:
        return cached[1]

    payload = {
        "query": query,
        "search_depth": "basic",
        "chunks_per_source": 2,
        "max_results": 3,
        "topic": "general",
        "include_answer": False,
        "include_raw_content": False,
        "include_images": False,
        "include_image_descriptions": False,
        "include_favicon": False,
        "auto_parameters": False,
        "safe_search": True,
    }
    request = urllib.request.Request(
        TAVILY_ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {tavily_key()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=TAVILY_TIMEOUT) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"Tavily failed {error.code}: {body[:600]}", file=sys.stderr)
        return None
    except Exception as error:
        print(f"Tavily failed: {error}", file=sys.stderr)
        return None

    facts: list[str] = []
    sources: list[dict[str, str]] = []
    for result in data.get("results") or []:
        title = clean_text(result.get("title"), limit=100)
        url = clean_text(result.get("url"), limit=240)
        content = result.get("content") or ""
        if title and url:
            sources.append({"title": title, "url": url})
        for candidate in split_fact_candidates(content):
            if is_safe_fact_snippet(candidate) and candidate not in facts:
                facts.append(candidate)
            if len(facts) >= limit:
                break
        if len(facts) >= limit:
            break

    if not facts:
        return None

    retrieved = {
        "label": label,
        "facts": facts[:limit],
        "safetyNotes": [
            "Ask a grown-up before opening, tasting, or using unfamiliar objects."
        ],
        "sources": sources[:3],
        "source": "tavily",
    }
    TAVILY_CACHE[cache_key] = (time.time(), retrieved)
    return retrieved


def merge_retrieved_facts(local: dict[str, Any], tavily: dict[str, Any] | None) -> dict[str, Any]:
    if not tavily:
        return local

    facts: list[str] = []
    for fact in (tavily.get("facts") or []) + (local.get("facts") or []):
        text = clean_text(fact, limit=180)
        if text and text not in facts:
            facts.append(text)

    safety_notes: list[str] = []
    for note in (local.get("safetyNotes") or []) + (tavily.get("safetyNotes") or []):
        text = clean_text(note, limit=180)
        if text and text not in safety_notes:
            safety_notes.append(text)

    merged = {
        "label": tavily.get("label") or local.get("label") or "object",
        "facts": facts[:6],
        "safetyNotes": safety_notes[:4],
        "source": "tavily+local",
    }
    if tavily.get("sources"):
        merged["sources"] = tavily["sources"]
    return merged


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
You are Kida's careful visual identifier for a child's learning app.
Look at the single main object the child framed near the image center. Ignore background objects, people, app UI, screen controls, and virtual AR overlays.
Return ONLY one valid JSON object. No markdown, no comments, no thinking text.

Detector hint from the phone. Verify it visually, but use it when the image supports it:
- label: {detector.get("label", "object")}
- confidence: {detector.get("confidence", 0)}
- alternatives: {", ".join(alternatives) if alternatives else "none"}

Use exactly these keys: primaryLabel, characterName, confidence, visualSummary, colors, material, shape, brand, readableText, likelyUses, safetyNotes, uncertainty, personality, emotion, voiceGender, voiceFamily.

Rules:
- primaryLabel is one common lowercase noun for the target object.
- characterName is a fun, specific, kid-friendly name for this object character, 1-3 words in Title Case.
- confidence is a number from 0 to 1.
- visualSummary is one short factual sentence about visible color, shape, material, or visible parts.
- colors, readableText, likelyUses, and safetyNotes are arrays with at most 4 strings.
- brand is a short brand name only when a logo or readable brand text is clearly visible; otherwise null.
- readableText is [] when no text is clearly readable.
- material and shape may be null when not visible.
- uncertainty is exactly one of: low, medium, high.
- personality is exactly one of: boss, cool, fancy, sweet, cautious.
- emotion is exactly one of: happy, sad, angry.
- voiceGender is exactly one of: man, woman.
- voiceFamily is exactly one of: bright, gentle, confident, careful.
- Be the eyes only: describe what is visible. Do not explain general object knowledge beyond obvious safe everyday uses.
- Never identify people. Never guess brands, hidden text, or hidden parts.
- Choose personality by what the object is:
  boss = authority, money, control, status, or important household items; examples: cash, wallet, credit card, safe/piggy bank, remote control, keys, calculator, phone, laptop.
  cool = fun, sport, play, style, trend, activity, or entertainment; examples: ball, skateboard, sneakers, headphones, sunglasses, bicycle, controller, guitar.
  fancy = formal, elegant, decorative, special-occasion, or treated carefully because it is nice; examples: fancy glassware, watch, perfume bottle, framed photo, trophy, vase, fancy tableware.
  sweet = comfort, softness, care, affection, or nurturing; examples: pillow, blanket, stuffed toy, plush, teapot, baby bottle, tissue box, flower.
  cautious = physically dangerous or adult-supervision objects; examples: scissors, knife, stove, electrical outlet, medicine bottle, lighter, chemical cleaner.
- If the target looks dangerous, set personality="cautious", emotion="angry", voiceFamily="careful", and add a safety note that asks for a grown-up.
- Choose voiceGender and voiceFamily as a stable character identity. Do not output raw TTS provider voice IDs.
- Choose characterName from the object, color, shape, safe use, or personality. Avoid generic repeated names like "Sunny Bottle". Do not use a brand unless brand is visible.

Example format:
{{"primaryLabel":"bottle","characterName":"Sip Scout","confidence":0.82,"visualSummary":"A tall white bottle with a smooth cylindrical body.","colors":["white"],"material":"plastic or metal","shape":"tall cylinder","brand":null,"readableText":[],"likelyUses":["holding drinks"],"safetyNotes":[],"uncertainty":"low","personality":"cool","emotion":"happy","voiceGender":"woman","voiceFamily":"bright"}}

Now return the JSON for this image.
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
    personality = map_personality(label)
    dangerous = personality == "cautious"
    return {
        "primaryLabel": label,
        "characterName": character_name_for(label, personality),
        "confidence": confidence,
        "visualSummary": f"The local detector thinks this is a {label}.",
        "colors": [],
        "material": None,
        "shape": None,
        "brand": None,
        "readableText": [],
        "likelyUses": [],
        "safetyNotes": ["Ask a grown-up before touching or using this."] if dangerous else [],
        "uncertainty": "high" if confidence < 0.45 else "medium",
        "personality": personality,
        "emotion": default_emotion(personality),
        "voiceGender": stable_voice_gender(label),
        "voiceFamily": voice_family_for_personality(personality),
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

    for key in ["material", "shape", "brand", "uncertainty"]:
        value = merged.get(key)
        merged[key] = str(value).strip() if value not in (None, "") else None
    if merged.get("brand"):
        brand = clean_text(merged["brand"], limit=60)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 &'.-]{0,58}", brand):
            brand = None
        merged["brand"] = brand

    merged["visualSummary"] = str(merged.get("visualSummary") or fallback["visualSummary"]).strip()
    danger = is_dangerous(merged["primaryLabel"], merged.get("safetyNotes", []))
    explicit_personality = explicit_personality_for_label(
        merged["primaryLabel"],
        merged.get("safetyNotes", []),
    )
    personality_fallback = map_personality(merged["primaryLabel"], merged.get("safetyNotes", []))
    merged["personality"] = sanitize_choice(
        merged.get("personality"),
        PERSONALITIES,
        personality_fallback,
    )
    if explicit_personality:
        merged["personality"] = explicit_personality
    if danger:
        merged["personality"] = "cautious"

    emotion_fallback = default_emotion(merged["personality"])
    merged["emotion"] = sanitize_choice(merged.get("emotion"), EMOTIONS, emotion_fallback)
    if danger:
        merged["emotion"] = "angry"

    merged["voiceGender"] = sanitize_choice(
        merged.get("voiceGender"),
        VOICE_GENDERS,
        stable_voice_gender(merged["primaryLabel"]),
    )
    family_fallback = voice_family_for_personality(merged["personality"])
    merged["voiceFamily"] = sanitize_choice(
        merged.get("voiceFamily"),
        VOICE_FAMILIES,
        family_fallback,
    )
    if danger:
        merged["voiceFamily"] = "careful"
    merged["characterName"] = sanitize_character_name(
        merged.get("characterName"),
        merged["primaryLabel"],
        merged["personality"],
    )
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
                    "tavilyConfigured": is_tavily_configured(),
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
            tavily_retrieved = tavily_retrieve_facts(card)
            retrieved = merge_retrieved_facts(retrieved, tavily_retrieved)
            suggested = retrieved.pop("suggestedQuestions", [])
            if tavily_retrieved:
                source = f"{source}+tavily"

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
