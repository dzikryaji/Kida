
> **Before you start:** Fill in Section 1 early. Once you move on to Section 2, don't go back and edit Section 1. The gap between what you guessed and what you actually found is the point of this whole document.


---
## Present your team

We are a team of 5

**Coder:**
- Aji
- Imelda
- Richard


**Designer:**
- Andrian
- Erin

---

## Starting Assumption

**We think we'll end up using:**

1. **A vision framework for object detection & segmentation** to detect and segment objects in the camera/scene.
2. **A vision-language model (VLM) framework** to determine the context of a detected object, in order to choose a "personality" for it.
3. **An AR kit (e.g. ARKit) to render eyes on the object** animating the eyes to express emotion tied to that object's assigned personality.
4. **A foundation model (LLM) for user object interaction** so the object can hold a conversation with the user, supporting both text and text-to-speech (TTS).
5. **AVSpeechSynthesizer for Text to Speech** so the object can interact with the user by the speech (talking).

<!-- Because:
[your reason, even if it's thin, e.g. "it sounded like the obvious fit"] -->

---
## The Exploration Log

*Not your conclusion, your actual process. Update this as you go, it doesn't need to be written in one sitting.*

**What we browsed, and what surprised us:**

- We found that foundation models can identify an object and infer some context around it, this was promising going in.
- ⁠Basic Vision object detection was okay, but not enough for placing eyes and mouth nicely.
- ⁠Bounding boxes help, but they feel too rough for a living object
- Segmentation is more useful than only detection because we need to know the object shape.
- ⁠Apple has Core ML SAM2 models on Hugging Face, and that was a better direction for tap-to-segment.
- ⁠Apple built-in TTS works, but the voice quality and emotion are not strong enough for a kid character experience.

**What we actually built or tested in code (not just read about):**

- When we actually tested it, the foundation model could only recognize an object at a basic/general level, it struggled to pick up finer details
- ⁠Vision / Core ML object detection using YOLO models
- ⁠Vision foreground segmentation
- ⁠Apple SAM2.1 Tiny Core ML segmentation
- ⁠Hybrid segmentation: SAM2 first, Vision fallback
- ASR using Apple Speech framework
- ⁠TTS using AVSpeechSynthesizer first
- ⁠ElevenLabs TTS as a better voice option
- ⁠Mouth animation that moves while speech is active
- ⁠Word-based mouth movement using speech timing where possible

**What we discovered that we didn't expect:**

- Even running on iOS 27, the foundation model's performance wasn't as strong as we expected.
- We discovered that the main problem is not only “can the AI detect the object?”
  The bigger problem is smoothness.
  If segmentation is too heavy, the camera feels laggy. If TTS waits too long, the character feels dead. If the mouth does not move at the same time as speech, the illusion breaks.
  So the app needs both AI quality and real-time performance.


---
## What We Tried and Dropped

**We considered:**
Using only bounding box object detection.

**We dropped it because:**
Bounding boxes are not accurate enough for placing the face nicely on real-world objects. Segmentation gives a better object shape and makes the object feel more “selected.”

**We also considered:**
Only Apple AVSpeechSynthesizer for production TTS.

**We dropped it as the main character voice because:**
It works and is Apple-first, but it sounds too flat for the character feeling we want. For kids, voice personality is very important.


---
## Real Limitations Hit

### Vision / Segmentation limitation

Vision segmentation was fast but not always accurate. Sometimes it selected the wrong part or the mask was not clean.

**How we worked around it:**
We added Apple Core ML SAM2.1 Tiny. Now the user taps the object, and SAM2 tries to segment that selected object. If SAM2 fails, the app falls back to Vision segmentation.

### Performance limitation

SAM-style segmentation is heavier than normal Vision. It can make the app feel laggy if we run it too often.

**How we worked around it:**
We made segmentation tap-based, not continuous. We also prewarm the model, cache the segmentation, cancel old segmentation tasks, and use CPU / Neural Engine so AR rendering has more room.

### ASR limitation

Apple Speech can crash or behave badly if permissions, audio session, or threading are not handled carefully.

**How we worked around it:**
We treated ASR as a controlled mode: start listening, update transcript, stop listening, then send the final question. We also stop TTS before listening so the app does not listen to itself.

### TTS limitation

Apple TTS is reliable but not expressive enough for our character voice goal.

**How we worked around it:**
We still keep AVSpeechSynthesizer as the Apple fallback, but for better character voice we explored ElevenLabs. The app can choose different voices based on the scanned object.


---
## The Revised Decision

- **Vision / Core ML:** object detection and fallback segmentation
- **Apple Core ML SAM2.1 Tiny:** tap-to-segment object mask
- **Apple Speech framework:** ASR
- **ElevenLabs TTS:** better expressive character voice
- **AVSpeechSynthesizer:** fallback TTS


---
## App Track Addendum

*(delete this whole section if you're a game team)*
### About the Frameworks


Yeah, we really do need them working together. Vision / Core ML gives us the object mask, and ARKit uses that mask to figure out where the eyes and mouth should go on the real object. Take segmentation away and the face lands in the wrong spot; take AR away and all we have is a mask with no character. Same story on the conversation side: Speech turns the kid's question into text, the language model answers in the object's personality, and TTS speaks it while the AR mouth moves along. Pull out any one of them and the "this thing is alive" illusion falls apart.

### About Accessibility and Localization


Kids can either talk to the object or type to it, so a child who can't (or doesn't want to) speak isn't left out. Answers also show up as text on screen, not just voice, so nothing depends on hearing alone.

We didn't localize. The speech recognition, the prompts, and the ElevenLabs character voices are all tuned for English, so adding a language means re-checking that whole voice pipeline. With our timeline, we'd rather make one language feel alive than make several feel flat.

### About Privacy


Kida asks for four permissions, and each one maps to a single feature:

- **Camera** — to spot objects and put the animated face on them. This is the only one the app really can't live without; no camera, no scanning.
- **Microphone + Speech Recognition** — so a kid can ask the object a question out loud. Say no to either and voice input just turns off; the kid can type the question instead.
- **Local Network** — to send the selected object image to a Mac on the same network for understanding, instead of a cloud service. Say no and that path is off.

We don't store or upload anything beyond that. Detection and segmentation run on-device with Core ML, and image understanding stays on the local network instead of going to the cloud.

