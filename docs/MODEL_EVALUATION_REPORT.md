# MODEL TRAINING AND EVALUATION REPORT

## 1. Genuine Epoch History Coverage
- **Complete Runs (24 runs, 1,128 epoch rows):** 15 Ultralytics YOLOv8n runs (`phase4c`, `phase4g`, `phase4l`, `phase4n`, `phase4o5`, `phase4o5_1`, `phase4o6 D0–D4`) + 9 MobileNetV3-Small verifier runs (`phase4o10`, `phase4o11 N1–N3`, `phase4o15 N4–N6, C2`).
- **Unavailable / Pretrained Runs (4 runs):** Phase 5.5 Kannada CRNN (`train_metrics.json` summary only), Phase 5.11 experimental CRNN, pretrained PP-OCRv5, and pretrained Arjuna SVTRv2.

![Phase 4L Banknote Losses](figures/train_phase4l_banknote_losses.png)
![Phase 4L Banknote Metrics](figures/train_phase4l_banknote_metrics.png)
![Phase 4L Banknote LR and Duration](figures/train_phase4l_banknote_lr_time.png)
![Phase 4N Coin Losses](figures/train_phase4n_coin_losses.png)
![Phase 4N Coin Metrics](figures/train_phase4n_coin_metrics.png)
![Phase 4N Coin LR and Duration](figures/train_phase4n_coin_lr_time.png)
![Phase 4O6 Coin Ablation D0-D4](figures/train_phase4o6_d0_d4_comparison.png)
![Note Verifier N5 Loss & Acc](figures/train_phase4o15_n5_verifier_loss_acc.png)
![Coin Verifier 4O10 Loss & Acc](figures/train_phase4o10_coin_verifier_loss_acc.png)
![Note Verifiers N1-N3 Comparison](figures/train_phase4o11_n1_n3_verifier_comparison.png)
![Phase 4O15 Verifiers Comparison](figures/train_phase4o15_n4_n6_c2_comparison.png)

## 2. Confusion Matrices & Verifier Comparison
Raw and row-normalized confusion matrices and per-class precision/recall/F1 (`VERIFIER_CLASSIFICATION_REPORT.csv`) cover all 9 verifier models.

![Note Verifiers N0-N3 Confusion Matrices](figures/cm_raw_n0_n3_note_verifiers.png)
![Experimental Coin Verifier C2 Normalized CM](figures/cm_norm_c2_coin_verifier.png)
![Verifier N3-N6 Rejection Comparison](figures/eval_verifier_n3_n6_rejection.png)
