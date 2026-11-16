# Changelog

## v1.0.0 (2026-11-16)
- Initial public release of **Sanetra** (`com.visionassistant.vision_assistant.visionmission`).
- Offline Indian banknote (`₹10`–`₹500`) and coin (`₹1`–`₹10`) recognition with `N5` and `4O10` identity verifiers.
- Offline multilingual OCR (English, Kannada `scene_arjuna_first` + `CRNN`, Hindi) with curved-label unwarping and reading-order sorting.
- Offline Google TTS (`en-IN`, `kn-IN`, `hi-IN`) with serialized queue and preemptive 4-second volume-key language selector.
- Double Volume Up OCR reread (`450 ms`) and automatic ambient-light flashlight (`Sensor.TYPE_LIGHT`).
- Optional GitHub Releases update checker (`AppUpdateService`) with SHA-256 verification and `FileProvider` install handoff.
