import os
import sys
import json
import hashlib
import numpy as np
from pathlib import Path
from PIL import Image
import cv2
from concurrent.futures import ProcessPoolExecutor, as_completed
from collections import defaultdict, Counter

ROOT = Path("C:/VisionMission")
CURRENCY_RAW = ROOT / "data/currency/raw"
REPORT_DIR = ROOT / "data/currency/audit_reports"
REPORT_DIR.mkdir(parents=True, exist_ok=True)

def compute_dhash(image, hash_size=8):
    # Grayscale and resize to (hash_size + 1, hash_size)
    resized = cv2.resize(image, (hash_size + 1, hash_size), interpolation=cv2.INTER_AREA)
    if len(resized.shape) == 3:
        resized = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    # Compare adjacent pixels
    diff = resized[:, 1:] > resized[:, :-1]
    # Convert to hex string
    decimal_value = 0
    hex_str = []
    for index, value in enumerate(diff.flatten()):
        if value:
            decimal_value += 2 ** (index % 8)
        if (index % 8) == 7:
            hex_str.append(hex(decimal_value)[2:].rjust(2, '0'))
            decimal_value = 0
    return "".join(hex_str)

def audit_single_image(args):
    dataset_name, rel_path, full_path_str = args
    full_path = Path(full_path_str)
    
    result = {
        "dataset": dataset_name,
        "rel_path": rel_path,
        "filename": full_path.name,
        "is_valid": False,
        "error": None,
        "size_bytes": 0,
        "width": 0,
        "height": 0,
        "channels": 0,
        "aspect_ratio": 0.0,
        "md5": None,
        "dhash": None,
        "blur_score": 0.0,
        "brightness": 0.0,
        "contrast": 0.0
    }
    
    try:
        sz = full_path.stat().st_size
        result["size_bytes"] = sz
        if sz == 0:
            result["error"] = "Zero byte file"
            return result
        
        # MD5
        with open(full_path, "rb") as f:
            md5_hash = hashlib.md5(f.read()).hexdigest()
        result["md5"] = md5_hash
        
        # Read image with OpenCV
        img = cv2.imread(str(full_path))
        if img is None:
            # Fallback to PIL to verify if OpenCV failed due to format
            pil_img = Image.open(full_path)
            pil_img.verify()
            pil_img = Image.open(full_path)
            img = np.array(pil_img)
            if len(img.shape) == 2:
                img = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
            elif img.shape[2] == 4:
                img = cv2.cvtColor(img, cv2.COLOR_RGBA2BGR)
            elif img.shape[2] == 3 and pil_img.mode == "RGB":
                img = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
                
        h, w = img.shape[:2]
        c = img.shape[2] if len(img.shape) > 2 else 1
        
        result["width"] = w
        result["height"] = h
        result["channels"] = c
        result["aspect_ratio"] = round(w / h, 4) if h > 0 else 0.0
        
        # dHash
        result["dhash"] = compute_dhash(img)
        
        # Blur metric (Laplacian variance)
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if c > 1 else img
        result["blur_score"] = round(float(cv2.Laplacian(gray, cv2.CV_64F).var()), 2)
        result["brightness"] = round(float(np.mean(gray)), 2)
        result["contrast"] = round(float(np.std(gray)), 2)
        result["is_valid"] = True
        
    except Exception as e:
        result["error"] = str(e)
        result["is_valid"] = False
        
    return result

def audit_currency_annotations():
    tb_path = CURRENCY_RAW / "Indian_Thai_BankNotes_Dataset/Indian_Thai_BankNotes_Dataset/IndianBankNotes"
    annot_audit = {
        "total_annotation_files": 0,
        "valid_files": 0,
        "invalid_files": 0,
        "total_bounding_boxes": 0,
        "classes_encountered": Counter(),
        "out_of_bounds_boxes": 0,
        "degenerate_boxes": 0,
        "per_class_box_stats": defaultdict(lambda: {"count": 0, "widths": [], "heights": []}),
        "split_counts": {"Training": 0, "Validation": 0}
    }
    
    if not tb_path.exists():
        return annot_audit
        
    for split in ["Training", "Validation"]:
        split_dir = tb_path / split
        if not split_dir.exists():
            continue
        for class_dir in split_dir.iterdir():
            if not class_dir.is_dir():
                continue
            for txt_file in class_dir.glob("*.txt"):
                annot_audit["total_annotation_files"] += 1
                annot_audit["split_counts"][split] += 1
                try:
                    with open(txt_file, "r") as f:
                        lines = [l.strip() for l in f.readlines() if l.strip()]
                    
                    if not lines:
                        annot_audit["invalid_files"] += 1
                        continue
                        
                    file_valid = True
                    for line in lines:
                        parts = line.split()
                        if len(parts) != 5:
                            file_valid = False
                            continue
                        cls_id = int(parts[0])
                        xc, yc, w, h = map(float, parts[1:])
                        
                        annot_audit["total_bounding_boxes"] += 1
                        annot_audit["classes_encountered"][cls_id] += 1
                        
                        # Check bounds
                        if not (0 <= xc <= 1 and 0 <= yc <= 1 and 0 < w <= 1 and 0 < h <= 1):
                            annot_audit["out_of_bounds_boxes"] += 1
                        if w <= 0.001 or h <= 0.001:
                            annot_audit["degenerate_boxes"] += 1
                            
                        annot_audit["per_class_box_stats"][cls_id]["count"] += 1
                        if len(annot_audit["per_class_box_stats"][cls_id]["widths"]) < 500:
                            annot_audit["per_class_box_stats"][cls_id]["widths"].append(round(w, 4))
                            annot_audit["per_class_box_stats"][cls_id]["heights"].append(round(h, 4))
                            
                    if file_valid:
                        annot_audit["valid_files"] += 1
                    else:
                        annot_audit["invalid_files"] += 1
                except Exception:
                    annot_audit["invalid_files"] += 1
                    
    annot_audit["classes_encountered"] = dict(annot_audit["classes_encountered"])
    for cls_id in annot_audit["per_class_box_stats"]:
        ws = annot_audit["per_class_box_stats"][cls_id]["widths"]
        hs = annot_audit["per_class_box_stats"][cls_id]["heights"]
        annot_audit["per_class_box_stats"][cls_id]["mean_w"] = round(float(np.mean(ws)), 4) if ws else 0
        annot_audit["per_class_box_stats"][cls_id]["mean_h"] = round(float(np.mean(hs)), 4) if hs else 0
        del annot_audit["per_class_box_stats"][cls_id]["widths"]
        del annot_audit["per_class_box_stats"][cls_id]["heights"]
    annot_audit["per_class_box_stats"] = dict(annot_audit["per_class_box_stats"])
    return annot_audit

def main():
    print("Collecting currency image file list...")
    tasks = []
    image_exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
    
    for ds_folder in CURRENCY_RAW.iterdir():
        if not ds_folder.is_dir():
            continue
        ds_name = ds_folder.name
        for root, _, files in os.walk(ds_folder):
            for f in files:
                ext = Path(f).suffix.lower()
                if ext in image_exts:
                    full_p = Path(root) / f
                    rel_p = str(full_p.relative_to(CURRENCY_RAW))
                    tasks.append((ds_name, rel_p, str(full_p)))
                    
    print(f"Total currency images to audit: {len(tasks)}")
    
    results = []
    # Use ProcessPoolExecutor for high-speed parallel audit
    max_workers = min(os.cpu_count() or 4, 8)
    print(f"Executing parallel image audit on {max_workers} worker processes...")
    
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        for idx, res in enumerate(executor.map(audit_single_image, tasks, chunksize=100)):
            results.append(res)
            if (idx + 1) % 1000 == 0 or (idx + 1) == len(tasks):
                print(f"Audited {idx + 1}/{len(tasks)} images...")

    # Aggregate statistics
    print("Aggregating currency audit results...")
    md5_map = defaultdict(list)
    dhash_map = defaultdict(list)
    dataset_stats = defaultdict(lambda: {
        "total": 0, "valid": 0, "corrupt": 0, 
        "widths": [], "heights": [], "aspect_ratios": [], 
        "blur_scores": [], "brightnesses": [], "contrasts": []
    })
    corrupt_images = []
    
    for r in results:
        ds = r["dataset"]
        dataset_stats[ds]["total"] += 1
        if not r["is_valid"]:
            dataset_stats[ds]["corrupt"] += 1
            corrupt_images.append(r)
        else:
            dataset_stats[ds]["valid"] += 1
            dataset_stats[ds]["widths"].append(r["width"])
            dataset_stats[ds]["heights"].append(r["height"])
            dataset_stats[ds]["aspect_ratios"].append(r["aspect_ratio"])
            dataset_stats[ds]["blur_scores"].append(r["blur_score"])
            dataset_stats[ds]["brightnesses"].append(r["brightness"])
            dataset_stats[ds]["contrasts"].append(r["contrast"])
            
            md5_map[r["md5"]].append((r["dataset"], r["rel_path"]))
            dhash_map[r["dhash"]].append((r["dataset"], r["rel_path"]))

    # Duplicates analysis
    exact_duplicates = {k: v for k, v in md5_map.items() if len(v) > 1}
    near_duplicates = {k: v for k, v in dhash_map.items() if len(v) > 1}
    
    summary_report = {
        "total_images_scanned": len(results),
        "valid_images": len(results) - len(corrupt_images),
        "corrupt_images_count": len(corrupt_images),
        "exact_duplicate_groups": len(exact_duplicates),
        "exact_duplicate_total_files": sum(len(v) for v in exact_duplicates.values()),
        "near_duplicate_dhash_groups": len(near_duplicates),
        "near_duplicate_total_files": sum(len(v) for v in near_duplicates.values()),
        "dataset_breakdowns": {}
    }
    
    for ds, st in dataset_stats.items():
        summary_report["dataset_breakdowns"][ds] = {
            "total_images": st["total"],
            "valid_images": st["valid"],
            "corrupt_images": st["corrupt"],
            "resolution": {
                "min_width": int(np.min(st["widths"])) if st["widths"] else 0,
                "max_width": int(np.max(st["widths"])) if st["widths"] else 0,
                "mean_width": round(float(np.mean(st["widths"])), 1) if st["widths"] else 0,
                "min_height": int(np.min(st["heights"])) if st["heights"] else 0,
                "max_height": int(np.max(st["heights"])) if st["heights"] else 0,
                "mean_height": round(float(np.mean(st["heights"])), 1) if st["heights"] else 0,
                "mean_aspect_ratio": round(float(np.mean(st["aspect_ratios"])), 3) if st["aspect_ratios"] else 0
            },
            "quality": {
                "mean_blur_score": round(float(np.mean(st["blur_scores"])), 1) if st["blur_scores"] else 0,
                "mean_brightness": round(float(np.mean(st["brightnesses"])), 1) if st["brightnesses"] else 0,
                "mean_contrast": round(float(np.mean(st["contrasts"])), 1) if st["contrasts"] else 0
            }
        }
        
    print("\nAuditing annotations in Indian_Thai_BankNotes_Dataset...")
    annotation_audit = audit_currency_annotations()
    
    # Analyze Multi_Note burst shot timing and clustering
    multi_note_bursts = defaultdict(list)
    for r in results:
        if r["dataset"] == "Multi_Note" and r["is_valid"]:
            # Filename format IMG_YYYYMMDD_HHMMSS.jpg
            fname = r["filename"]
            if fname.startswith("IMG_") and len(fname) >= 19:
                timestamp_key = fname[4:17] # YYYYMMDD_HHMM
                multi_note_bursts[timestamp_key].append(r["rel_path"])
                
    burst_summary = {
        "total_multi_note_images": len([r for r in results if r["dataset"] == "Multi_Note"]),
        "burst_clusters_count": len(multi_note_bursts),
        "cluster_sizes": {k: len(v) for k, v in sorted(multi_note_bursts.items(), key=lambda x: -len(x[1]))[:15]}
    }
    
    # Save reports
    with open(REPORT_DIR / "currency_audit_summary.json", "w", encoding="utf-8") as f:
        json.dump(summary_report, f, indent=2)
    with open(REPORT_DIR / "currency_corrupt.json", "w", encoding="utf-8") as f:
        json.dump(corrupt_images, f, indent=2)
    with open(REPORT_DIR / "currency_duplicates.json", "w", encoding="utf-8") as f:
        json.dump({
            "exact_duplicate_groups_count": len(exact_duplicates),
            "exact_duplicates": {k: v for idx, (k, v) in enumerate(exact_duplicates.items()) if idx < 50},
            "near_duplicate_dhash_groups_count": len(near_duplicates),
            "near_duplicates": {k: v for idx, (k, v) in enumerate(near_duplicates.items()) if idx < 50}
        }, f, indent=2)
    with open(REPORT_DIR / "currency_bounding_box_audit.json", "w", encoding="utf-8") as f:
        json.dump(annotation_audit, f, indent=2)
    with open(REPORT_DIR / "currency_burst_analysis.json", "w", encoding="utf-8") as f:
        json.dump(burst_summary, f, indent=2)

    print("\n=== CURRENCY AUDIT COMPLETED ===")
    print(f"Total Scanned: {summary_report['total_images_scanned']}")
    print(f"Valid: {summary_report['valid_images']}, Corrupt: {summary_report['corrupt_images_count']}")
    print(f"Exact Duplicate Groups: {summary_report['exact_duplicate_groups']} ({summary_report['exact_duplicate_total_files']} files)")
    print(f"Near Duplicate Groups: {summary_report['near_duplicate_dhash_groups']} ({summary_report['near_duplicate_total_files']} files)")
    print(f"Bounding Boxes Audited: {annotation_audit['total_bounding_boxes']} across {annotation_audit['total_annotation_files']} files")
    print(f"Multi_Note Burst Clusters: {burst_summary['burst_clusters_count']}")
    print(f"All reports written to {REPORT_DIR}")

if __name__ == "__main__":
    main()

