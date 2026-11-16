# Third-Party Notices and Audio Attribution

## Bisaya (`ceb-PH`) Currency Audio Clips (`app/final_app/assets/audio/bisaya/*.wav`)

- **Asset Inventory:** 43 normalized 16 kHz mono 16-bit PCM WAV clips (`1,560,938` bytes total) covering Bisaya selector confirmation (`"Bisaya"`), Cebuano cardinal/tens number words (`0`–`19`, `20`–`90`, `gatos`, `libo`), and Indian Rupee currency phrasing (`rupee`, `papel`, `sensilyo`, prompts, and uncertainty warnings).
- **Provenance & Attribution:** These 43 clips were synthesized offline via `build_bisaya_clips.py` from Meta AI's Massively Multilingual Speech (MMS) Cebuano text-to-speech model (`facebook/mms-tts-ceb`, `https://huggingface.co/facebook/mms-tts-ceb`), normalized to `-3.0 dBFS`, trimmed, and crossfaded (`8 ms`) for zero-synthesis-delay `AudioTrack` concatenation.
- **License & Restrictions:** `facebook/mms-tts-ceb` is licensed under **CC-BY-NC 4.0** (Creative Commons Attribution-NonCommercial 4.0). Derived audio clips retain **CC-BY-NC 4.0** attribution and non-commercial distribution terms. Neither the raw PyTorch weights nor the ONNX neural model (`mms_tts_ceb_*.onnx`) are bundled in the Sanetra APK or public GitHub repository.
