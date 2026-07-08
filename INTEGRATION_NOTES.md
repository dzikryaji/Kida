# Integrating VLM + Foundation Model + Sticker onto main

Branch `integrate/vlm-afm-sticker`, based on `origin/main` (237e4d4).

**Goal:** add the VLM (object understanding), Apple Foundation Model persona, and the sticker
feature. Morph rig, ASR/TTS, and experimental UI intentionally **stay on main** (excluded).
Full originals live on branch `andrian/vision-asr-tts`.

> ⚠️ **Not compile-verified.** This was assembled in an environment with only Command Line
> Tools (no Xcode.app), so the Swift side was never built. main also uses a **different
> architecture** than the sandbox (`Kida/` layout, `ScanViewModel`/`ARSessionViewModel`,
> hand-maintained `kida.xcodeproj` — no XcodeGen). So the Swift files are **staged, not
> wired**. Finish in Xcode per the checklist below.

## ✅ Landed & self-contained (no wiring needed)
- **`Server/`** — Mac VLM server (`kida_vlm_server.py`, `mlx_vlm_runner.py`) + sticker backend
  (`sticker_service.py`) + `object_facts.json` + requirements. Pure Python, runs standalone.
  See `Server/README.md`.
- **`.gitignore`** — main had none; this protects `Secrets.xcconfig` (API keys), venvs, and
  model downloads. **Keep it.**

## 🔶 Staged in `Kida/Service/` — need Xcode wiring
- `ObjectIntelligenceServices.swift` — VLM object understanding: `MacVLMVisualUnderstandingProvider`
  (dev → your Mac server) + `GeminiVisualUnderstandingProvider` (TestFlight/cloud) in a cascade,
  plus a local fact store (RAG).
- `FoundationPersonaGenerator.swift` — Apple Foundation Models persona/chat, with grounding + safety.
- `StickerService.swift` — die-cut sticker (Apple Vision / SAM2 on-device; optional server tier).
- `ObjectLabelNormalizer.swift` — helper the fact store needs.

## Finish in Xcode — checklist
1. **Add the 4 files to the `kida` target** (no XcodeGen on main — drag in / check target
   membership). Until added they aren't compiled (so they don't break the build now either).
2. **Add missing type to `Kida/Models/KidaModels.swift`:**
   `ObjectIntelligenceCard` — copy from `andrian/vision-asr-tts:Models/KidaModels.swift` (~line 44).
   It's central to both VLM and AFM.
3. **Augment existing types** (main's versions lack fields the features use):
   - `DetectedObject` → add `capturedImage: UIImage?`, `alternatives: [String]`,
     `visualContext: String?`, `objectIntelligence: ObjectIntelligenceCard?`.
   - `ChatResponse` → add `grounded: Bool?`, `usedFacts: [String]?`.
   - `Emotion` → add `case angry`, `case sad` (and handle them in the face factory, or clamp
     AFM output to main's existing cases).
4. **Sticker segmenter reconciliation:** `StickerService` calls the sandbox segmenter API
   (`VisionObjectSegmenter.segment(cgImage:…)`, `SAM2ObjectSegmenter`). main already has its own
   `Kida/Service/{SAM2,Vision}ObjectSegmenter.swift` — reconcile the API (port the sandbox methods,
   or adapt `StickerService` to main's signatures).
5. **Wire into the flow:** main has no `KidaViewModel`. Call
   `CascadingVisualUnderstandingProvider().makeObjectUnderstanding(for:)` where an object is
   detected (likely `ScanViewModel` / `ARSessionViewModel`), then feed the resulting card into
   `FoundationPersonaGenerator`.
6. **Config:** add Info.plist keys read by the providers — `GeminiAPIKey`, `GeminiModelID`,
   `VLMServerURL`, `VLMServerToken`, `VLMServerTimeout` — fed from `Secrets.xcconfig` (gitignored).
   VLM model default is `gemini-2.5-flash`. In dev set `VLM_SERVER_URL` to your Mac's LAN IP; leave
   it **empty** for TestFlight so it goes straight to Gemini.
7. **Gemini key security:** the key ships inside the app → restrict it (Generative Language API
   only + quota/budget) and rotate; enable **billing / paid tier** so images aren't used for
   training (matters for a kids' app); proxy it for real public distribution.
8. **Build & verify** — could not be done in this environment.

## Reference
Full original implementations (including the morph rig, ASR/TTS, and UI that deliberately stay on
main): branch **`andrian/vision-asr-tts`**.
