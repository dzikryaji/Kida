
> **Before you start:** Fill in Section 1 early. Once you move on to Section 2, don't go back and edit Section 1. The gap between what you guessed and what you actually found is the point of this whole document.


---
## Present your team

We are a team of 5

- Andrian
- Erin
- Imelda
- Richard
- Aji

---

## Starting Assumption


**We think we'll end up using:**

1. **A vision framework for object detection & segmentation** to detect and segment objects in the camera/scene.
3. **An AR kit (e.g. ARKit) to render eyes on the object** animating the eyes to express emotion tied to that object's assigned personality.
4. **A foundation model (LLM) for user object interaction** so the object can hold a conversation with the user, supporting both text and text-to-speech (TTS).
4. **Apple Speech framework for Automatic Speech Recognition** for speech to text.
5. **AVSpeechSynthesizer for Text to Speech** so the object can interact with the user by the speech (talking).


---
## The Exploration Log


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
- SmolVLM on VLM model that apple provide works better than foundation model
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


### Vision Language Model limitation

SmolVLM gave us accurate results, but the model is heavy for an on-device chatbot: around 1 GB, which is a lot to ship inside a native app.

**How we worked around it:**


---
## The Revised Decision

- **Vision / Core ML:** object detection and fallback segmentation
- **Apple Core ML SAM2.1 Tiny:** tap-to-segment object mask
- **VLM (Vision-Language Model):** object context and chatbot interaction
- **Apple Speech framework:** ASR
- **ElevenLabs TTS:** better expressive character voice
- **AVSpeechSynthesizer:** fallback TTS



---
## App Track Addendum

*(delete this whole section if you're a game team)*
### About the Frameworks

*Does your use case genuinely need both frameworks working together, or could it work with just your main one?*
[ ]
### About Accessibility and Localization

*What did you decide to support, what did you decide not to, and why? "We didn't localize" is a fine answer if you can say why, "we didn't think about it" is not.*
[ ]
### About Privacy

*What data does your app actually need? What happens in your app when the user says no to a permission?*
[ ]

---
## Game Track Addendum

*(delete this whole section if you're an app team)*
### About the Mechanics

*Describe the core mechanic that emerged from your pairing. If this reads like a list of frameworks, it's not done yet.*
[ ]
### About Player Experience

*Player Experience, before and after****:*** *Write the sentence you started with, and the one you ended with: "[Mechanic] makes [moment] feel [feeling], instead of [feeling without it]."*
Before: [ ] After: [ ]
### About the Game Engine

*If you used Unity or Godot****:*** *Exporting to iOS isn't the same as using an Apple framework. How did you bridge into a genuine Apple framework (GameKit, HealthKit, etc.) from the native side?*
[ ]

