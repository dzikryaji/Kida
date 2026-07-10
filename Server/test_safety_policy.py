#!/usr/bin/env python3
"""Focused regression checks for Kida's object-risk policy."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


SERVER_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVER_DIR))

import kida_vlm_server as server  # noqa: E402
import mlx_vlm_runner as runner  # noqa: E402


class ObjectRiskPolicyTests(unittest.TestCase):
    @staticmethod
    def sanitize(card: dict) -> dict:
        return server.sanitized_card(
            card,
            {
                "label": card.get("primaryLabel", "object"),
                "confidence": 0.8,
                "alternatives": [],
            },
        )

    def test_generic_safety_note_does_not_force_cautious(self) -> None:
        card = self.sanitize({
            "primaryLabel": "cup",
            "personality": "caregiver",
            "emotion": "happy",
            "voiceFamily": "gentle",
            "safetyNotes": ["Do not touch hot drinks."],
        })

        self.assertEqual(card["riskLevel"], "none")
        self.assertIsNone(card["riskReason"])
        self.assertEqual(card["personality"], "caregiver")
        self.assertEqual(card["emotion"], "happy")
        self.assertEqual(card["voiceFamily"], "gentle")

    def test_contextual_objects_keep_their_character(self) -> None:
        for label, personality in [("fork", "fancy"), ("cable organizer", "fancy"), ("battery pack", "cool")]:
            with self.subTest(label=label):
                card = self.sanitize({
                    "primaryLabel": label,
                    "personality": personality,
                    "emotion": "happy",
                    "voiceFamily": "gentle",
                    "riskLevel": "contextual",
                })
                self.assertEqual(card["riskLevel"], "contextual")
                self.assertEqual(card["personality"], personality)
                self.assertEqual(card["emotion"], "happy")

    def test_inherently_hazardous_object_still_hard_overrides(self) -> None:
        card = self.sanitize({
            "primaryLabel": "kitchen knife",
            "personality": "cool",
            "emotion": "happy",
            "voiceFamily": "bright",
            "riskLevel": "none",
        })

        self.assertEqual(card["riskLevel"], "high")
        self.assertEqual(card["personality"], "cautious")
        self.assertEqual(card["emotion"], "angry")
        self.assertEqual(card["voiceFamily"], "careful")

    def test_visible_active_hazard_can_promote_contextual_object(self) -> None:
        active = self.sanitize({
            "primaryLabel": "candle",
            "personality": "fancy",
            "emotion": "happy",
            "voiceFamily": "gentle",
            "riskLevel": "high",
            "riskReason": "A visible flame is burning.",
        })
        hypothetical = self.sanitize({
            "primaryLabel": "candle",
            "personality": "fancy",
            "emotion": "happy",
            "voiceFamily": "gentle",
            "riskLevel": "high",
            "riskReason": "Candles can burn things.",
        })

        self.assertEqual(active["riskLevel"], "high")
        self.assertEqual(active["personality"], "cautious")
        self.assertEqual(hypothetical["riskLevel"], "contextual")
        self.assertEqual(hypothetical["personality"], "fancy")

    def test_explicit_toy_or_child_safe_variant_is_not_hard_locked(self) -> None:
        for label in ["toy gun", "pretend knife", "safety scissors"]:
            with self.subTest(label=label):
                card = self.sanitize({
                    "primaryLabel": label,
                    "personality": "cool",
                    "emotion": "happy",
                    "voiceFamily": "bright",
                })
                self.assertEqual(card["riskLevel"], "contextual")
                self.assertNotEqual(card["personality"], "cautious")
                self.assertEqual(card["emotion"], "happy")

    def test_qwen_character_fields_survive_runner_normalization(self) -> None:
        source = {
            "primaryLabel": "fork",
            "confidence": 0.9,
            "visualSummary": "A silver fork.",
            "brand": "Kida",
            "personality": "fancy",
            "emotion": "happy",
            "voiceGender": "woman",
            "voiceFamily": "gentle",
            "riskLevel": "contextual",
            "riskReason": "Its prongs need careful handling.",
        }

        card = runner.extract_card(json.dumps(source))

        self.assertEqual(card["personality"], "fancy")
        self.assertEqual(card["emotion"], "happy")
        self.assertEqual(card["voiceGender"], "woman")
        self.assertEqual(card["voiceFamily"], "gentle")
        self.assertEqual(card["riskLevel"], "contextual")
        self.assertEqual(card["brand"], "Kida")


if __name__ == "__main__":
    unittest.main()
