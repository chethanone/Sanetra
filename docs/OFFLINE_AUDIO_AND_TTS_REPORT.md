# OFFLINE AUDIO AND TTS REPORT

## 1. Engine & Approved Offline Voices
`SpeechService` (`lib/services/speech_service.dart`) wraps `flutter_tts` using offline Google TTS (`com.google.android.tts`):
- **English (`en-IN`):** `en-in-x-enc-local`
- **Kannada (`kn-IN`):** `kn-in-x-knd-local`
- **Hindi (`hi-IN`):** `hi-in-x-hia-local`

## 2. Serialized Queue & Preemption
- **Epoch-Guarded `_serialQueue`:** Guarantees single-utterance execution without audio overlap.
- **Language Selector Preemption (`announceSelectorLanguage`):** Increments `_speechEpoch` and stops active speech immediately so rapid navigation speaks only the latest selected language.
- **Non-Interrupting Status Queue (`enqueueShortAnnouncement`):** Queues `"Flashlight on."` / `"Flashlight off."` (and Kannada/Hindi equivalents) onto `_serialQueue` without interrupting ongoing currency or OCR recognition announcements.
