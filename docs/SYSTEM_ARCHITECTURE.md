# SYSTEM ARCHITECTURE

```text
+-----------------------------------------------------------------------+
|                    SANETRA ANDROID APP (Flutter + Kotlin)             |
|  Package: com.visionassistant.vision_assistant.visionmission          |
+-----------------------------------+-----------------------------------+
                                    |
        +---------------------------+---------------------------+
        v                           v                           v
+---------------+         +-------------------+       +-----------------+
| Currency Mode |         |     OCR Mode      |       | Hardware & UX   |
| (Live YUV +   |         | (Auto Capture +   |       | - Vol Keys (Kt) |
|  Snapshot)    |         |  450ms Reread)    |       | - 4s Lang Popup |
+-------+-------+         +---------+---------+       | - TYPE_LIGHT    |
        |                           |                 |   Auto-Torch    |
        v                           v                 +--------+--------+
+---------------+         +-------------------+                |
| YOLOv8n ONNX  |         | PP-OCRv5 Det ONNX |                |
| Banknote (4L) |         | + Geometry /      |                |
| Coin (4N)     |         |   Reading Order   |                |
+-------+-------+         +---------+---------+                |
        |                           |                          |
        v                           v                          |
+---------------+         +-------------------+                |
| MobileNetV3   |         | EN / HI PP-OCRv5  |                |
| Verifier N5 / |         | KA CRNN + Arjuna  |                |
| Coin 4O10     |         | SVTRv2 Scene-1st  |                |
+-------+-------+         +---------+---------+                |
        |                           |                          |
        +-------------+-------------+--------------------------+
                      v
        +-----------------------------------+
        | SpeechService (_serialQueue)      |
        | Offline Google TTS (en/kn/hi-IN)  |
        +-----------------------------------+
```
