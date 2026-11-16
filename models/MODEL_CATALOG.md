# MODEL CATALOG

## 1. Production & Experimental Models in `final_app/assets/models/`

| Model File | Status | Size (MB) | Input Tensor | Output Tensor | SHA-256 (Prefix) |
|---|---|---:|---|---|---|
| `best.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 11.88 | `[('images', [1, 3, 960, 960])]` | `[('output0', [1, 10, 18900])]` | `9C3AA10BE94B4B98...` |
| `indian_banknote_phase4l_candidate.onnx` | PRODUCTION_ACTIVE | 12.19 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 10, 8400])]` | `9D7364B952BD4EA0...` |
| `indian_banknote_yolov8n_candidate.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.19 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 10, 8400])]` | `DA860BD967D1B3D9...` |
| `indian_coin_d3_candidate.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.18 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 8, 8400])]` | `B9C593CD1961E404...` |
| `indian_coin_d4_candidate.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.18 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 8, 8400])]` | `55BBDE676DE5DF42...` |
| `indian_coin_phase4n_candidate.onnx` | PRODUCTION_ACTIVE | 12.18 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 8, 8400])]` | `A620A64B07193F07...` |
| `indian_coin_phase4o5_1_candidate_c.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.18 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 8, 8400])]` | `987B36DA244CD958...` |
| `indian_coin_yolov8n_candidate.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.18 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 8, 8400])]` | `A276F30F45C48006...` |
| `indian_coin_verifier.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 5.81 | `[('input', [1, 3, 224, 224])]` | `[('logits', [1, 3])]` | `B11B52983F50A293...` |
| `n3_note_verifier.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 5.81 | `[('input', [1, 3, 224, 224])]` | `[('logits', [1, 3])]` | `FB695A35DBE4091A...` |
| `indian_coin_verifier.onnx` | PRODUCTION_ACTIVE | 5.81 | `[('input', [1, 3, 224, 224])]` | `[('logits', [1, 3])]` | `B11B52983F50A293...` |
| `n5_note_verifier.onnx` | PRODUCTION_ACTIVE | 5.81 | `[('input', [1, 3, 224, 224])]` | `[('logits', [1, 3])]` | `9459AAC058FD37B0...` |
| `indian_banknote_yolov8n.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.19 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 10, 8400])]` | `F6B172B5F03C168B...` |
| `indian_coin_yolov8n.onnx` | BUNDLED_LEGACY_OR_CANDIDATE | 12.18 | `[('images', [1, 3, 640, 640])]` | `[('output0', [1, 8, 8400])]` | `E3FB6CBBA17022F4...` |
| `detector.onnx` | PRODUCTION_ACTIVE | 4.6 | `[('x', ['DynamicDimension.0', 3, 'DynamicDimension.1', 'DynamicDimension.2'])]` | `[('fetch_name_0', ['ConvTranspose_521_o0__d0', 1, 'ConvTranspose_521_o0__d2', 'ConvTranspose_521_o0__d3'])]` | `A431985659DC9219...` |
| `recognizer_hi.onnx` | PRODUCTION_ACTIVE | 7.57 | `[('x', ['DynamicDimension.0', 3, 48, 'DynamicDimension.1'])]` | `[('fetch_name_0', ['DynamicDimension.0', 'Reshape_552_o0__d2', 570])]` | `034908C7AF333EA2...` |
| `recognizer_ka.onnx` | PRODUCTION_ACTIVE | 10.55 | `[('x', ['batch', 3, 48, 'width'])]` | `[('fetch_name_0', ['batch', 'seq_len', 165])]` | `56C61794DEB7B2BB...` |
| `recognizer_ka_scene.onnx` | PRODUCTION_ACTIVE | 19.99 | `[('image', ['batch', 3, 32, 'width'])]` | `[('probs', ['batch', 'time', 221])]` | `D107D078248CE898...` |
| `recognizer.onnx` | PRODUCTION_ACTIVE | 7.48 | `[('x', ['DynamicDimension.0', 3, 48, 'DynamicDimension.1'])]` | `[('fetch_name_0', ['DynamicDimension.2', 'DynamicDimension.3', 438])]` | `B5F833DFC5D0EB71...` |

*(Full 64-character SHA-256 hashes are recorded in `MODEL_FILE_INVENTORY.csv`.)*