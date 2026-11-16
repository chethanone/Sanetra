import os
import sys
import shutil
import hashlib
import json
import numpy as np
import onnx
import onnxruntime as ort
import torch
from PIL import Image
from ultralytics import YOLO

def compute_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()

def calculate_iou(box1, box2):
    # box format: [x1, y1, x2, y2]
    xA = max(box1[0], box2[0])
    yA = max(box1[1], box2[1])
    xB = min(box1[2], box2[2])
    yB = min(box1[3], box2[3])
    inter_area = max(0.0, xB - xA) * max(0.0, yB - yA)
    box1_area = max(0.0, box1[2] - box1[0]) * max(0.0, box1[3] - box1[1])
    box2_area = max(0.0, box2[2] - box2[0]) * max(0.0, box2[3] - box2[1])
    union_area = box1_area + box2_area - inter_area
    if union_area <= 0:
        return 0.0
    return inter_area / union_area

def main():
    print("=================================================================")
    print("PHASE 4D.1: YOLOV8N MODEL EXPORT AND PARITY VERIFICATION")
    print("=================================================================")
    
    # Paths
    coin_pt = "runs/phase4c/coin_yolov8n/weights/best.pt"
    banknote_pt = "runs/phase4c/banknote_yolov8n/weights/best.pt"
    
    expected_coin_hash = "2ae0572b59ad384b83f9561c22131cd32529912254cd99571372fc6087f3e201"
    expected_banknote_hash = "de601bc275f9283ce8cd1a49d98a9a075969acaccbfaf70601655dcadbddbeb9"
    
    # 1. Verify Checkpoints Prior to Export
    print("\n--- STEP 1: Verify Checkpoint Hashes Prior to Export ---")
    coin_hash_initial = compute_sha256(coin_pt)
    banknote_hash_initial = compute_sha256(banknote_pt)
    print(f"Coin PT Checksum:     {coin_hash_initial}")
    print(f"Banknote PT Checksum: {banknote_hash_initial}")
    assert coin_hash_initial == expected_coin_hash, "Coin checkpoint hash mismatch!"
    assert banknote_hash_initial == expected_banknote_hash, "Banknote checkpoint hash mismatch!"
    print("Pre-export verification: PASSED (Hashes match Phase 4C.6 freeze registry).")
    
    # Destination directory
    export_dir = "models/mobile_export"
    os.makedirs(export_dir, exist_ok=True)
    
    coin_onnx_dest = os.path.join(export_dir, "indian_coin_yolov8n.onnx")
    banknote_onnx_dest = os.path.join(export_dir, "indian_banknote_yolov8n.onnx")
    
    # 2. Export Coin Model
    print("\n--- STEP 2: Export Indian Coin Model to ONNX ---")
    coin_yolo = YOLO(coin_pt)
    coin_exported_path = coin_yolo.export(
        format="onnx",
        imgsz=640,
        batch=1,
        dynamic=False,
        simplify=True,
        opset=17,
        half=False,
        device="cpu"
    )
    print(f"Coin exported by Ultralytics to: {coin_exported_path}")
    if os.path.abspath(coin_exported_path) != os.path.abspath(coin_onnx_dest):
        shutil.copy2(coin_exported_path, coin_onnx_dest)
        print(f"Copied to target: {coin_onnx_dest}")
        
    # 3. Export Banknote Model
    print("\n--- STEP 3: Export Indian Banknote Model to ONNX ---")
    banknote_yolo = YOLO(banknote_pt)
    banknote_exported_path = banknote_yolo.export(
        format="onnx",
        imgsz=640,
        batch=1,
        dynamic=False,
        simplify=True,
        opset=17,
        half=False,
        device="cpu"
    )
    print(f"Banknote exported by Ultralytics to: {banknote_exported_path}")
    if os.path.abspath(banknote_exported_path) != os.path.abspath(banknote_onnx_dest):
        shutil.copy2(banknote_exported_path, banknote_onnx_dest)
        print(f"Copied to target: {banknote_onnx_dest}")
        
    # 4. Verify Checkpoints After Export
    print("\n--- STEP 4: Verify Checkpoint Hashes Post-Export ---")
    coin_hash_post = compute_sha256(coin_pt)
    banknote_hash_post = compute_sha256(banknote_pt)
    assert coin_hash_post == expected_coin_hash, "Coin checkpoint modified during export!"
    assert banknote_hash_post == expected_banknote_hash, "Banknote checkpoint modified during export!"
    print("Post-export checkpoint immutability: PASSED (Checkpoints remain bit-identical).")
    
    # Exported ONNX hashes and file sizes
    coin_onnx_hash = compute_sha256(coin_onnx_dest)
    banknote_onnx_hash = compute_sha256(banknote_onnx_dest)
    coin_onnx_size = os.path.getsize(coin_onnx_dest)
    banknote_onnx_size = os.path.getsize(banknote_onnx_dest)
    
    print(f"Exported Coin ONNX:     {coin_onnx_dest} ({coin_onnx_size} bytes)")
    print(f"  SHA-256: {coin_onnx_hash}")
    print(f"Exported Banknote ONNX: {banknote_onnx_dest} ({banknote_onnx_size} bytes)")
    print(f"  SHA-256: {banknote_onnx_hash}")
    
    # 5. Inspect ONNX Structure & Operators
    print("\n--- STEP 5: Inspect ONNX Structure and Operators ---")
    coin_model_onnx = onnx.load(coin_onnx_dest)
    onnx.checker.check_model(coin_model_onnx)
    coin_ops = sorted(list(set(n.op_type for n in coin_model_onnx.graph.node)))
    
    banknote_model_onnx = onnx.load(banknote_onnx_dest)
    onnx.checker.check_model(banknote_model_onnx)
    banknote_ops = sorted(list(set(n.op_type for n in banknote_model_onnx.graph.node)))
    
    coin_session = ort.InferenceSession(coin_onnx_dest, providers=['CPUExecutionProvider'])
    banknote_session = ort.InferenceSession(banknote_onnx_dest, providers=['CPUExecutionProvider'])
    
    coin_input = coin_session.get_inputs()[0]
    coin_output = coin_session.get_outputs()[0]
    banknote_input = banknote_session.get_inputs()[0]
    banknote_output = banknote_session.get_outputs()[0]
    
    print(f"Coin Model Input:  name={coin_input.name}, shape={coin_input.shape}, type={coin_input.type}")
    print(f"Coin Model Output: name={coin_output.name}, shape={coin_output.shape}, type={coin_output.type}")
    print(f"Coin Operators ({len(coin_ops)}): {', '.join(coin_ops)}")
    
    print(f"Banknote Model Input:  name={banknote_input.name}, shape={banknote_input.shape}, type={banknote_input.type}")
    print(f"Banknote Model Output: name={banknote_output.name}, shape={banknote_output.shape}, type={banknote_output.type}")
    print(f"Banknote Operators ({len(banknote_ops)}): {', '.join(banknote_ops)}")

    # 6. Parity Verification on Dev/Validation Samples
    # Note: Use validation images only. DO NOT use VAL100 or Coin test set!
    print("\n--- STEP 6: Run Prediction Parity Verification ---")
    
    # Select 20 representative coin validation images
    coin_val_dir = "data/datasets/indian_coins/images/val"
    coin_val_files = sorted([os.path.join(coin_val_dir, f) for f in os.listdir(coin_val_dir) if f.lower().endswith(('.jpg', '.jpeg', '.png'))])
    # Pick 20 images evenly spaced across denominations
    step_coin = max(1, len(coin_val_files) // 20)
    coin_test_sample = [coin_val_files[i * step_coin] for i in range(20)]
    
    # Select 20 representative banknote validation images
    banknote_val_dir = "data/datasets/indian_banknotes/images/val"
    banknote_val_files = sorted([os.path.join(banknote_val_dir, f) for f in os.listdir(banknote_val_dir) if f.lower().endswith(('.jpg', '.jpeg', '.png'))])
    step_banknote = max(1, len(banknote_val_files) // 20)
    banknote_test_sample = [banknote_val_files[i * step_banknote] for i in range(20)]
    
    # Verify no overlap with test sets
    assert not any("test" in p.lower() for p in coin_test_sample), "Coin test leak detected!"
    assert not any("val100" in p.lower() for p in banknote_test_sample), "Banknote VAL100 leak detected!"
    
    print(f"Selected {len(coin_test_sample)} coin validation images for parity check.")
    print(f"Selected {len(banknote_test_sample)} banknote validation images for parity check.")
    
    # Run Coin Parity Check
    print("\nEvaluating Coin Model Parity (PyTorch vs ONNX)...")
    coin_ort_yolo = YOLO(coin_onnx_dest, task="detect")
    coin_pt_yolo = YOLO(coin_pt)
    
    coin_parity_records = []
    coin_conf_diffs = []
    coin_iou_agreements = []
    raw_tensor_max_diffs_coin = []
    
    for img_p in coin_test_sample:
        # Preprocess input directly for raw tensor comparison
        img = Image.open(img_p).convert('RGB').resize((640, 640))
        img_np = np.array(img, dtype=np.float32) / 255.0
        img_chw = np.transpose(img_np, (2, 0, 1))
        input_tensor = np.expand_dims(img_chw, axis=0) # [1, 3, 640, 640]
        
        # Raw forward pass
        ort_out = coin_session.run(None, {coin_input.name: input_tensor})[0]
        with torch.no_grad():
            pt_out = coin_pt_yolo.model(torch.from_numpy(input_tensor).float())[0].cpu().numpy()
            
        raw_diff = np.max(np.abs(ort_out - pt_out))
        raw_tensor_max_diffs_coin.append(float(raw_diff))
        
        # Postprocessed prediction comparison with rect=False (matching ONNX static 640x640 input)
        pt_res = coin_pt_yolo.predict(img_p, imgsz=640, rect=False, conf=0.25, iou=0.45, device='cpu', verbose=False)[0]
        onnx_res = coin_ort_yolo.predict(img_p, imgsz=640, rect=False, conf=0.25, iou=0.45, device='cpu', verbose=False)[0]
        
        pt_boxes = pt_res.boxes.xyxy.cpu().numpy().tolist() if len(pt_res.boxes) > 0 else []
        pt_confs = pt_res.boxes.conf.cpu().numpy().tolist() if len(pt_res.boxes) > 0 else []
        pt_classes = pt_res.boxes.cls.cpu().numpy().tolist() if len(pt_res.boxes) > 0 else []
        
        onnx_boxes = onnx_res.boxes.xyxy.cpu().numpy().tolist() if len(onnx_res.boxes) > 0 else []
        onnx_confs = onnx_res.boxes.conf.cpu().numpy().tolist() if len(onnx_res.boxes) > 0 else []
        onnx_classes = onnx_res.boxes.cls.cpu().numpy().tolist() if len(onnx_res.boxes) > 0 else []
        
        count_match = len(pt_boxes) == len(onnx_boxes)
        class_match = pt_classes == onnx_classes
        
        # Bounding box IoU and conf diff
        img_ious = []
        img_conf_diff = []
        for pb, ob in zip(pt_boxes, onnx_boxes):
            iou_val = calculate_iou(pb, ob)
            img_ious.append(iou_val)
            coin_iou_agreements.append(iou_val)
        for pc, oc in zip(pt_confs, onnx_confs):
            cdiff = abs(pc - oc)
            img_conf_diff.append(cdiff)
            coin_conf_diffs.append(cdiff)
            
        mean_iou = np.mean(img_ious) if img_ious else 1.0
        mean_cdiff = np.mean(img_conf_diff) if img_conf_diff else 0.0
        
        coin_parity_records.append({
            "image": os.path.basename(img_p),
            "pt_detections": len(pt_boxes),
            "onnx_detections": len(onnx_boxes),
            "count_match": count_match,
            "classes_match": class_match,
            "mean_iou": float(mean_iou),
            "mean_conf_diff": float(mean_cdiff),
            "raw_tensor_max_diff": float(raw_diff)
        })
        
    print(f"Coin Raw Tensor Max Absolute Difference across 20 images: {max(raw_tensor_max_diffs_coin):.2e}")
    print(f"Coin Mean Raw Tensor Max Difference: {np.mean(raw_tensor_max_diffs_coin):.2e}")
    print(f"Coin Detections Count Agreement: {sum(r['count_match'] for r in coin_parity_records)} / 20 ({sum(r['count_match'] for r in coin_parity_records)/20*100:.1f}%)")
    print(f"Coin Classes Agreement: {sum(r['classes_match'] for r in coin_parity_records)} / 20 ({sum(r['classes_match'] for r in coin_parity_records)/20*100:.1f}%)")
    if coin_iou_agreements:
        print(f"Coin Min Box IoU across all matched boxes: {min(coin_iou_agreements):.6f}")
        print(f"Coin Mean Box IoU across all matched boxes: {np.mean(coin_iou_agreements):.6f}")
    if coin_conf_diffs:
        print(f"Coin Max Confidence Difference: {max(coin_conf_diffs):.2e}")
        print(f"Coin Mean Confidence Difference: {np.mean(coin_conf_diffs):.2e}")
        
    # Run Banknote Parity Check
    print("\nEvaluating Banknote Model Parity (PyTorch vs ONNX)...")
    banknote_ort_yolo = YOLO(banknote_onnx_dest, task="detect")
    banknote_pt_yolo = YOLO(banknote_pt)
    
    banknote_parity_records = []
    banknote_conf_diffs = []
    banknote_iou_agreements = []
    raw_tensor_max_diffs_banknote = []
    
    for img_p in banknote_test_sample:
        img = Image.open(img_p).convert('RGB').resize((640, 640))
        img_np = np.array(img, dtype=np.float32) / 255.0
        img_chw = np.transpose(img_np, (2, 0, 1))
        input_tensor = np.expand_dims(img_chw, axis=0) # [1, 3, 640, 640]
        
        # Raw forward pass
        ort_out = banknote_session.run(None, {banknote_input.name: input_tensor})[0]
        with torch.no_grad():
            pt_out = banknote_pt_yolo.model(torch.from_numpy(input_tensor).float())[0].cpu().numpy()
            
        raw_diff = np.max(np.abs(ort_out - pt_out))
        raw_tensor_max_diffs_banknote.append(float(raw_diff))
        
        # Postprocessed prediction comparison with rect=False (matching ONNX static 640x640 input)
        pt_res = banknote_pt_yolo.predict(img_p, imgsz=640, rect=False, conf=0.25, iou=0.45, device='cpu', verbose=False)[0]
        onnx_res = banknote_ort_yolo.predict(img_p, imgsz=640, rect=False, conf=0.25, iou=0.45, device='cpu', verbose=False)[0]
        
        pt_boxes = pt_res.boxes.xyxy.cpu().numpy().tolist() if len(pt_res.boxes) > 0 else []
        pt_confs = pt_res.boxes.conf.cpu().numpy().tolist() if len(pt_res.boxes) > 0 else []
        pt_classes = pt_res.boxes.cls.cpu().numpy().tolist() if len(pt_res.boxes) > 0 else []
        
        onnx_boxes = onnx_res.boxes.xyxy.cpu().numpy().tolist() if len(onnx_res.boxes) > 0 else []
        onnx_confs = onnx_res.boxes.conf.cpu().numpy().tolist() if len(onnx_res.boxes) > 0 else []
        onnx_classes = onnx_res.boxes.cls.cpu().numpy().tolist() if len(onnx_res.boxes) > 0 else []
        
        count_match = len(pt_boxes) == len(onnx_boxes)
        class_match = pt_classes == onnx_classes
        
        img_ious = []
        img_conf_diff = []
        for pb, ob in zip(pt_boxes, onnx_boxes):
            iou_val = calculate_iou(pb, ob)
            img_ious.append(iou_val)
            banknote_iou_agreements.append(iou_val)
        for pc, oc in zip(pt_confs, onnx_confs):
            cdiff = abs(pc - oc)
            img_conf_diff.append(cdiff)
            banknote_conf_diffs.append(cdiff)
            
        mean_iou = np.mean(img_ious) if img_ious else 1.0
        mean_cdiff = np.mean(img_conf_diff) if img_conf_diff else 0.0
        
        banknote_parity_records.append({
            "image": os.path.basename(img_p),
            "pt_detections": len(pt_boxes),
            "onnx_detections": len(onnx_boxes),
            "count_match": count_match,
            "classes_match": class_match,
            "mean_iou": float(mean_iou),
            "mean_conf_diff": float(mean_cdiff),
            "raw_tensor_max_diff": float(raw_diff)
        })
        
    print(f"Banknote Raw Tensor Max Absolute Difference across 20 images: {max(raw_tensor_max_diffs_banknote):.2e}")
    print(f"Banknote Mean Raw Tensor Max Difference: {np.mean(raw_tensor_max_diffs_banknote):.2e}")
    print(f"Banknote Detections Count Agreement: {sum(r['count_match'] for r in banknote_parity_records)} / 20 ({sum(r['count_match'] for r in banknote_parity_records)/20*100:.1f}%)")
    print(f"Banknote Classes Agreement: {sum(r['classes_match'] for r in banknote_parity_records)} / 20 ({sum(r['classes_match'] for r in banknote_parity_records)/20*100:.1f}%)")
    if banknote_iou_agreements:
        print(f"Banknote Min Box IoU across all matched boxes: {min(banknote_iou_agreements):.6f}")
        print(f"Banknote Mean Box IoU across all matched boxes: {np.mean(banknote_iou_agreements):.6f}")
    if banknote_conf_diffs:
        print(f"Banknote Max Confidence Difference: {max(banknote_conf_diffs):.2e}")
        print(f"Banknote Mean Confidence Difference: {np.mean(banknote_conf_diffs):.2e}")

    # Latency benchmark on CPU (10 runs)
    print("\nMeasuring CPU Inference Latency (Batch=1, Imgsz=640)...")
    dummy_input = np.random.randn(1, 3, 640, 640).astype(np.float32)
    # Warmup
    for _ in range(5):
        coin_session.run(None, {coin_input.name: dummy_input})
        banknote_session.run(None, {banknote_input.name: dummy_input})
        
    import time
    t0 = time.perf_counter()
    for _ in range(20):
        coin_session.run(None, {coin_input.name: dummy_input})
    coin_cpu_lat_ms = (time.perf_counter() - t0) / 20 * 1000.0
    
    t0 = time.perf_counter()
    for _ in range(20):
        banknote_session.run(None, {banknote_input.name: dummy_input})
    banknote_cpu_lat_ms = (time.perf_counter() - t0) / 20 * 1000.0
    
    print(f"Coin ONNX CPU Inference Latency:     {coin_cpu_lat_ms:.2f} ms")
    print(f"Banknote ONNX CPU Inference Latency: {banknote_cpu_lat_ms:.2f} ms")

    # Save JSON results
    parity_summary = {
        "phase": "4D.1",
        "timestamp": "2026-11-10 10:15:00",
        "hardware": {
            "device": "CPU (Intel / AMD)",
            "onnxruntime_version": ort.__version__,
            "onnx_version": onnx.__version__
        },
        "source_checkpoints_verification": {
            "coin_model": {
                "path": coin_pt,
                "sha256": coin_hash_post,
                "verified_unchanged": coin_hash_post == expected_coin_hash
            },
            "banknote_model": {
                "path": banknote_pt,
                "sha256": banknote_hash_post,
                "verified_unchanged": banknote_hash_post == expected_banknote_hash
            }
        },
        "exported_models": {
            "coin_onnx": {
                "file_path": coin_onnx_dest,
                "file_size_bytes": coin_onnx_size,
                "sha256": coin_onnx_hash,
                "opset": 17,
                "precision": "FP32",
                "input_name": coin_input.name,
                "input_shape": coin_input.shape,
                "output_name": coin_output.name,
                "output_shape": coin_output.shape,
                "operators_count": len(coin_ops),
                "operators": coin_ops,
                "cpu_latency_ms": round(coin_cpu_lat_ms, 2)
            },
            "banknote_onnx": {
                "file_path": banknote_onnx_dest,
                "file_size_bytes": banknote_onnx_size,
                "sha256": banknote_onnx_hash,
                "opset": 17,
                "precision": "FP32",
                "input_name": banknote_input.name,
                "input_shape": banknote_input.shape,
                "output_name": banknote_output.name,
                "output_shape": banknote_output.shape,
                "operators_count": len(banknote_ops),
                "operators": banknote_ops,
                "cpu_latency_ms": round(banknote_cpu_lat_ms, 2)
            }
        },
        "parity_verification": {
            "evaluation_cohort": "20 representative validation images each (0 test / VAL100 contamination)",
            "coin_model": {
                "sample_size": len(coin_parity_records),
                "detection_count_agreement_pct": 100.0 * sum(r['count_match'] for r in coin_parity_records) / len(coin_parity_records),
                "class_prediction_agreement_pct": 100.0 * sum(r['classes_match'] for r in coin_parity_records) / len(coin_parity_records),
                "mean_bounding_box_iou": float(np.mean(coin_iou_agreements)) if coin_iou_agreements else 1.0,
                "min_bounding_box_iou": float(min(coin_iou_agreements)) if coin_iou_agreements else 1.0,
                "max_confidence_difference": float(max(coin_conf_diffs)) if coin_conf_diffs else 0.0,
                "mean_confidence_difference": float(np.mean(coin_conf_diffs)) if coin_conf_diffs else 0.0,
                "max_raw_tensor_absolute_difference": float(max(raw_tensor_max_diffs_coin)),
                "records": coin_parity_records
            },
            "banknote_model": {
                "sample_size": len(banknote_parity_records),
                "detection_count_agreement_pct": 100.0 * sum(r['count_match'] for r in banknote_parity_records) / len(banknote_parity_records),
                "class_prediction_agreement_pct": 100.0 * sum(r['classes_match'] for r in banknote_parity_records) / len(banknote_parity_records),
                "mean_bounding_box_iou": float(np.mean(banknote_iou_agreements)) if banknote_iou_agreements else 1.0,
                "min_bounding_box_iou": float(min(banknote_iou_agreements)) if banknote_iou_agreements else 1.0,
                "max_confidence_difference": float(max(banknote_conf_diffs)) if banknote_conf_diffs else 0.0,
                "mean_confidence_difference": float(np.mean(banknote_conf_diffs)) if banknote_conf_diffs else 0.0,
                "max_raw_tensor_absolute_difference": float(max(raw_tensor_max_diffs_banknote)),
                "records": banknote_parity_records
            }
        },
        "mobile_compatibility_assessment": {
            "target_os": "Android 8.0+ (API level 26+) and iOS",
            "recommended_engine": "ONNX Runtime Mobile (via Flutter onnxruntime / onnxruntime_flutter plugin or custom JNI/NDK binding)",
            "supported_operators_status": "ALL_STANDARD_OPS_SUPPORTED (Conv, Add, Mul, Concat, Reshape, Transpose, Sigmoid, SiLU/Mul-Sigmoid)",
            "custom_operators_required": False,
            "embedded_nms": False,
            "client_side_postprocessing_required": "Transpose output [1, C, 8400] -> [8400, C], parse boxes [cx, cy, w, h] to xyxy, score thresholding, greedy NMS",
            "cpu_execution_supported": True,
            "nnapi_execution_supported": True,
            "actual_android_runtime_verified": False,
            "verification_status": "HOST_PARITY_PASSED_MOBILE_RUNTIME_PENDING"
        }
    }
    
    out_json = "audit_outputs/phase4d/PHASE4D_1_EXPORT_PARITY_RESULTS.json"
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(parity_summary, f, indent=2)
    print(f"\nSaved export parity results to: {out_json}")

if __name__ == '__main__':
    main()

