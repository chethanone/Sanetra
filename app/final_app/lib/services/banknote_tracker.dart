import 'dart:math' as math;
import 'currency_model_service.dart';
import 'currency_safety_evaluator.dart';

class TrackedBanknote {
  final int id;
  int classId;
  String denomination;
  int value;
  double confidence;
  double x1;
  double y1;
  double x2;
  double y2;

  // Candidate safety & telemetry fields
  String type;
  int top2ClassId;
  String top2ClassName;
  double top2Confidence;
  double classMargin;
  int suppressedConflictCount;
  int suppressedConflictClassId;
  String suppressedConflictClassName;
  double suppressedConflictConfidence;
  double interBoxMaxIoU;
  double interBoxMaxIoMin;
  DetectionConfirmationState rawConfirmationState;
  List<String> rawUncertaintyReasons;

  int framesVisible;
  int framesMissing;
  final List<int> classHistory;
  final Map<int, double> _classEvidence = {};
  final List<int> _recentClasses = [];
  double _peakRecentConfidence = 0.0;
  int _consecutiveAltCount = 0;
  int _consecutiveAltClass = -1;
  bool hasClassOscillation = false;
  bool suspectedMergeGrowth = false;

  TrackedBanknote({
    required this.id,
    required this.classId,
    required this.denomination,
    required this.value,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.type = '',
    this.top2ClassId = -1,
    this.top2ClassName = '',
    this.top2Confidence = 0.0,
    this.classMargin = 1.0,
    this.suppressedConflictCount = 0,
    this.suppressedConflictClassId = -1,
    this.suppressedConflictClassName = '',
    this.suppressedConflictConfidence = 0.0,
    this.interBoxMaxIoU = 0.0,
    this.interBoxMaxIoMin = 0.0,
    this.rawConfirmationState = DetectionConfirmationState.confirmed,
    this.rawUncertaintyReasons = const [],
    this.framesVisible = 1,
    this.framesMissing = 0,
    List<int>? classHistory,
  }) : classHistory = classHistory ?? [classId] {
    _peakRecentConfidence = confidence;
    _recentClasses.add(classId);
    final w = confidence * (0.35 + 0.65 * classMargin.clamp(0.0, 1.0));
    _classEvidence[classId] = w;
    if (top2ClassId >= 0 && top2Confidence >= 0.20) {
      _classEvidence[top2ClassId] =
          (_classEvidence[top2ClassId] ?? 0.0) + top2Confidence * 0.25;
    }
  }

  bool get isCoin => type == 'coin' || denomination.contains('COIN') || classId >= 6;
  double get width => math.max(0.0, x2 - x1);
  double get height => math.max(0.0, y2 - y1);
  double get area => width * height;
  double get centerX => (x1 + x2) / 2.0;
  double get centerY => (y1 + y2) / 2.0;

  void updateLegacy(CurrencyDetection det) {
    framesVisible++;
    framesMissing = 0;

    const double alpha = 0.35;
    x1 = (1.0 - alpha) * x1 + alpha * det.x1;
    y1 = (1.0 - alpha) * y1 + alpha * det.y1;
    x2 = (1.0 - alpha) * x2 + alpha * det.x2;
    y2 = (1.0 - alpha) * y2 + alpha * det.y2;
    confidence = math.max(confidence * 0.9, det.confidence);

    if (det.classId != classId) {
      if (det.classId == _consecutiveAltClass) {
        _consecutiveAltCount++;
      } else {
        _consecutiveAltClass = det.classId;
        _consecutiveAltCount = 1;
      }

      if (det.confidence >= 0.55 && _consecutiveAltCount >= 2) {
        classId = det.classId;
        denomination = det.denomination;
        value = det.value;
        classHistory.clear();
        classHistory.addAll([det.classId, det.classId]);
        _consecutiveAltCount = 0;
        _consecutiveAltClass = -1;
        return;
      }
    } else {
      _consecutiveAltCount = 0;
      _consecutiveAltClass = -1;
    }

    classHistory.add(det.classId);
    if (classHistory.length > 5) {
      classHistory.removeAt(0);
    }

    final counts = <int, int>{};
    for (final c in classHistory) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    int bestClass = det.classId;
    int maxCount = -1;
    counts.forEach((c, count) {
      if (count > maxCount) {
        maxCount = count;
        bestClass = c;
      }
    });

    if (bestClass != classId && maxCount >= 3) {
      classId = bestClass;
      denomination = CurrencyModelService.classNames[bestClass];
      value = CurrencyModelService.denominationValues[bestClass];
    }
  }

  /// Phase 4M Candidate track update:
  /// - Never inflates weak current-frame confidence using stale past confidence
  /// - Detects class oscillation and sudden box-merge growth
  /// - Switches rapidly (2 consistent frames) without wrong-denomination lock-in
  void updateCandidate(CurrencyDetection det) {
    final prevArea = area;
    framesVisible++;
    framesMissing = 0;

    // Smooth slightly for rendering stability while preserving actual current confidence & conflict metrics
    const double alpha = 0.60;
    x1 = (1.0 - alpha) * x1 + alpha * det.x1;
    y1 = (1.0 - alpha) * y1 + alpha * det.y1;
    x2 = (1.0 - alpha) * x2 + alpha * det.x2;
    y2 = (1.0 - alpha) * y2 + alpha * det.y2;

    // Preserve exact current frame confidence & conflict telemetry (never mask weak frame!)
    confidence = det.confidence;
    type = det.type;
    top2ClassId = det.top2ClassId;
    top2ClassName = det.top2ClassName;
    top2Confidence = det.top2Confidence;
    classMargin = det.classMargin;
    suppressedConflictCount = det.suppressedConflictCount;
    suppressedConflictClassId = det.suppressedConflictClassId;
    suppressedConflictClassName = det.suppressedConflictClassName;
    suppressedConflictConfidence = det.suppressedConflictConfidence;
    interBoxMaxIoU = det.interBoxMaxIoU;
    interBoxMaxIoMin = det.interBoxMaxIoMin;
    rawConfirmationState = det.confirmationState;
    rawUncertaintyReasons = List<String>.from(det.uncertaintyReasons);

    // Flag suspicious sudden box growth indicative of two physical notes merging into 1 box
    suspectedMergeGrowth =
        !isCoin && prevArea > 0.0 && (det.area / prevArea > 1.60);
    _peakRecentConfidence = math.max(_peakRecentConfidence * 0.85, det.confidence);

    if (det.classId != classId) {
      if (det.classId == _consecutiveAltClass) {
        _consecutiveAltCount++;
      } else {
        _consecutiveAltClass = det.classId;
        _consecutiveAltCount = 1;
      }
    } else {
      _consecutiveAltCount = 0;
      _consecutiveAltClass = -1;
    }

    if (isCoin) {
      // Phase 4O.2 Confidence-Weighted Temporal Coin Evidence + Hysteresis:
      // Smooths transient 1-frame flicker without locking in an early wrong class or forcing ambiguous coins.
      for (final k in _classEvidence.keys.toList()) {
        _classEvidence[k] = _classEvidence[k]! * 0.72;
      }
      final double frameWeight =
          det.confidence * (0.35 + 0.65 * det.classMargin.clamp(0.0, 1.0));
      _classEvidence[det.classId] =
          (_classEvidence[det.classId] ?? 0.0) + frameWeight;
      if (det.top2ClassId >= 0 && det.top2Confidence >= 0.20) {
        _classEvidence[det.top2ClassId] =
            (_classEvidence[det.top2ClassId] ?? 0.0) + det.top2Confidence * 0.25;
      }

      int bestClass = det.classId;
      double bestEv = -1.0;
      double secondEv = 0.0;
      _classEvidence.forEach((cls, ev) {
        if (ev > bestEv) {
          secondEv = bestEv > 0.0 ? bestEv : 0.0;
          bestEv = ev;
          bestClass = cls;
        } else if (ev > secondEv) {
          secondEv = ev;
        }
      });

      final double currentEv = _classEvidence[classId] ?? 0.0;
      if (bestClass != classId &&
          (bestEv > currentEv * 1.15 ||
              (framesVisible <= 2 &&
                  det.classId == bestClass &&
                  _consecutiveAltCount >= 2))) {
        classId = bestClass;
        denomination = CurrencyModelService.classNames[bestClass];
        value = CurrencyModelService.denominationValues[bestClass];
        _consecutiveAltCount = 0;
        _consecutiveAltClass = -1;
      }

      _recentClasses.add(det.classId);
      if (_recentClasses.length > 4) {
        _recentClasses.removeAt(0);
      }

      final double dominanceRatio = bestEv > 0.0 ? secondEv / bestEv : 1.0;
      final bool recentTwoAgree = _recentClasses.length >= 2 &&
          _recentClasses.last == classId &&
          _recentClasses[_recentClasses.length - 2] == classId &&
          det.classMargin >= 0.25;
      final bool activeAltFlicker = det.classId != classId &&
          (det.confidence >= 0.45 || det.classMargin < 0.35);

      hasClassOscillation = activeAltFlicker ||
          dominanceRatio >= 0.50 ||
          (_recentClasses.toSet().length > 1 && !recentTwoAgree);
      return;
    }

    if (det.classId != classId) {
      if (_consecutiveAltCount >= 2) {
        // Two consecutive frames agree on the new denomination -> update cleanly
        classId = det.classId;
        denomination = det.denomination;
        value = det.value;
        classHistory
          ..clear()
          ..addAll([det.classId, det.classId]);
        _consecutiveAltCount = 0;
        _consecutiveAltClass = -1;
        hasClassOscillation = false;
        return;
      } else {
        hasClassOscillation = true;
      }
    }

    classHistory.add(det.classId);
    if (classHistory.length > 3) {
      classHistory.removeAt(0);
    }

    // Oscillation cleared once last 2 observations consistently agree on current class
    if (classHistory.length >= 2 &&
        classHistory.last == classId &&
        classHistory[classHistory.length - 2] == classId) {
      hasClassOscillation = false;
    } else if (classHistory.toSet().length > 1) {
      hasClassOscillation = true;
    }
  }

  void markMissing({required bool candidateMode}) {
    framesMissing++;
    if (candidateMode) {
      for (final k in _classEvidence.keys.toList()) {
        _classEvidence[k] = _classEvidence[k]! * 0.85;
      }
      _peakRecentConfidence *= 0.80;
      // Rapid decay on missed frame; never emit missing tracks to UI/total
      confidence *= isCoin ? 0.65 : 0.55;
      classMargin *= 0.60;
      _consecutiveAltCount = 0;
      _consecutiveAltClass = -1;
      if (!isCoin) {
        framesVisible = math.max(0, framesVisible - 1);
      }
    }
  }

  CurrencyDetection toDetection({bool candidateMode = false}) {
    final reasons = <String>{...rawUncertaintyReasons};
    var state = rawConfirmationState;

    if (candidateMode) {
      if (hasClassOscillation) {
        reasons.add('CLASS_OSCILLATION');
        state = DetectionConfirmationState.conflicting;
      }
      if (suspectedMergeGrowth) {
        reasons.add('MERGED_BOX_SUSPECTED');
        if (state == DetectionConfirmationState.confirmed) {
          state = DetectionConfirmationState.tentative;
        }
      }
    }

    return CurrencyDetection(
      classId: classId,
      denomination: denomination,
      value: value,
      confidence: confidence,
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      type: type,
      top2ClassId: top2ClassId,
      top2ClassName: top2ClassName,
      top2Confidence: top2Confidence,
      classMargin: classMargin,
      suppressedConflictCount: suppressedConflictCount,
      suppressedConflictClassId: suppressedConflictClassId,
      suppressedConflictClassName: suppressedConflictClassName,
      suppressedConflictConfidence: suppressedConflictConfidence,
      interBoxMaxIoU: interBoxMaxIoU,
      interBoxMaxIoMin: interBoxMaxIoMin,
      confirmationState: state,
      uncertaintyReasons: reasons.toList(),
      framesVisible: framesVisible,
      framesMissing: framesMissing,
    );
  }

  // Legacy stability / retention
  bool get isStableLegacy => (confidence >= 0.55) || (framesVisible >= 2);
  bool get shouldRetainLegacy => framesMissing <= 2;

  // Candidate retention: keep missing coin tracks up to 2 frames for brief blink recovery, NEVER emit missing tracks
  bool get shouldRetainCandidate => isCoin
      ? (framesMissing <= 2 && _peakRecentConfidence >= 0.30)
      : (framesMissing <= 1 && confidence >= 0.15);
}

class TrackerUpdateResult {
  final List<CurrencyDetection> activeDetections;
  final CurrencySafetyAssessment assessment;
  final int activeTrackCount;
  final int retainedMissingCount;
  final int droppedStaleCount;
  final int deduplicatedTrackCount;

  const TrackerUpdateResult({
    required this.activeDetections,
    required this.assessment,
    required this.activeTrackCount,
    required this.retainedMissingCount,
    required this.droppedStaleCount,
    required this.deduplicatedTrackCount,
  });
}

class _PairCandidate {
  final TrackedBanknote track;
  final CurrencyDetection det;
  final double score;
  final double iou;
  final double dist;

  const _PairCandidate({
    required this.track,
    required this.det,
    required this.score,
    required this.iou,
    required this.dist,
  });
}

class BanknoteTracker {
  final bool candidateMode;
  int _nextId = 1;
  int _stableMultiBaselineCount = 0;
  int _multiObjectStreak = 0;
  int _cooldownTargetCount = 0;
  int _incompleteSceneCooldown = 0;
  final List<TrackedBanknote> _tracks = [];

  BanknoteTracker({this.candidateMode = false});

  List<TrackedBanknote> get debugTracks => List.unmodifiable(_tracks);

  List<CurrencyDetection> update(List<CurrencyDetection> detections) {
    return updateWithSafety(detections).activeDetections;
  }

  TrackerUpdateResult updateWithSafety(
    List<CurrencyDetection> detections, {
    int imageWidth = 0,
    int imageHeight = 0,
    Set<String> extraReasons = const {},
  }) {
    if (!candidateMode) {
      return _updateLegacy(detections);
    }
    return _updateCandidate(
      detections,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      extraReasons: extraReasons,
    );
  }

  TrackerUpdateResult _updateLegacy(List<CurrencyDetection> detections) {
    final matchedTracks = <TrackedBanknote>{};
    final matchedDets = <CurrencyDetection>{};

    final sortedDets = List<CurrencyDetection>.from(detections)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    for (final det in sortedDets) {
      TrackedBanknote? bestTrack;
      double bestDist = double.infinity;

      final detCx = (det.x1 + det.x2) / 2.0;
      final detCy = (det.y1 + det.y2) / 2.0;
      final detW = det.x2 - det.x1;
      final detH = det.y2 - det.y1;
      final bool detIsCoin = det.isCoin;

      for (final track in _tracks) {
        if (matchedTracks.contains(track)) continue;
        if (track.isCoin != detIsCoin) continue;

        final dx = (track.centerX - detCx).abs() / math.max(track.width, 1.0);
        final dy = (track.centerY - detCy).abs() / math.max(track.height, 1.0);
        final dist = math.sqrt(dx * dx + dy * dy);

        final xx1 = math.max(track.x1, det.x1);
        final yy1 = math.max(track.y1, det.y1);
        final xx2 = math.min(track.x2, det.x2);
        final yy2 = math.min(track.y2, det.y2);
        final inter = math.max(0.0, xx2 - xx1) * math.max(0.0, yy2 - yy1);
        final union = track.width * track.height + detW * detH - inter;
        final iou = inter / (union + 1e-6);

        final double maxDist = detIsCoin ? 0.35 : 0.60;
        final double minIou = detIsCoin ? 0.15 : 0.22;

        if (iou > minIou || dist < maxDist) {
          if (dist < bestDist) {
            bestDist = dist;
            bestTrack = track;
          }
        }
      }

      if (bestTrack != null) {
        bestTrack.updateLegacy(det);
        matchedTracks.add(bestTrack);
        matchedDets.add(det);
      }
    }

    for (final track in _tracks) {
      if (!matchedTracks.contains(track)) {
        track.markMissing(candidateMode: false);
      }
    }

    _tracks.removeWhere((t) => !t.shouldRetainLegacy);

    for (final det in sortedDets) {
      if (!matchedDets.contains(det)) {
        _tracks.add(_createTrack(det));
      }
    }

    final emitted = _tracks
        .where((t) => t.isStableLegacy && t.framesMissing <= 1)
        .map((t) => t.toDetection())
        .toList();

    final assessment = CurrencySafetyEvaluator.evaluate(emitted, candidateMode: false);
    return TrackerUpdateResult(
      activeDetections: emitted,
      assessment: assessment,
      activeTrackCount: emitted.length,
      retainedMissingCount: _tracks.where((t) => t.framesMissing > 0).length,
      droppedStaleCount: 0,
      deduplicatedTrackCount: 0,
    );
  }

  TrackerUpdateResult _updateCandidate(
    List<CurrencyDetection> detections, {
    int imageWidth = 0,
    int imageHeight = 0,
    Set<String> extraReasons = const {},
  }) {
    if (detections.isEmpty) {
      for (final track in _tracks) {
        track.markMissing(candidateMode: true);
      }
      final int droppedStaleCount =
          _tracks.where((t) => !t.shouldRetainCandidate).length;
      _tracks.removeWhere((t) => !t.shouldRetainCandidate);
      _incompleteSceneCooldown = 0;
      _stableMultiBaselineCount = 0;
      _multiObjectStreak = 0;
      _cooldownTargetCount = 0;
      final assessment = CurrencySafetyEvaluator.evaluate(
        const [],
        candidateMode: true,
        extraReasons: extraReasons,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
      return TrackerUpdateResult(
        activeDetections: const [],
        assessment: assessment,
        activeTrackCount: 0,
        retainedMissingCount: _tracks.length,
        droppedStaleCount: droppedStaleCount,
        deduplicatedTrackCount: 0,
      );
    }

    // Preserve raw frame pairwise overlap metrics BEFORE EMA smoothing so motion lag cannot mask cross-class overlap conflicts
    final screenedInput = <CurrencyDetection>[];
    for (int i = 0; i < detections.length; i++) {
      final d = detections[i];
      double maxCrossClassIoU = d.interBoxMaxIoU;
      double maxCrossClassIoMin = d.interBoxMaxIoMin;
      for (int j = 0; j < detections.length; j++) {
        if (i == j || detections[j].isCoin != d.isCoin) continue;
        if (detections[j].classId != d.classId) {
          final iou = CurrencySafetyEvaluator.computeIoU(d, detections[j]);
          final iomin = CurrencySafetyEvaluator.computeIoMin(d, detections[j]);
          if (iou > maxCrossClassIoU) maxCrossClassIoU = iou;
          if (iomin > maxCrossClassIoMin) maxCrossClassIoMin = iomin;
        }
      }
      screenedInput.add(
        (maxCrossClassIoU > d.interBoxMaxIoU || maxCrossClassIoMin > d.interBoxMaxIoMin)
            ? d.copyWith(interBoxMaxIoU: maxCrossClassIoU, interBoxMaxIoMin: maxCrossClassIoMin)
            : d,
      );
    }

    final sortedDets = List<CurrencyDetection>.from(screenedInput)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    final pairs = <_PairCandidate>[];
    for (final track in _tracks) {
      for (final det in sortedDets) {
        if (track.isCoin != det.isCoin) continue;

        final detCx = (det.x1 + det.x2) / 2.0;
        final detCy = (det.y1 + det.y2) / 2.0;
        final dx = (track.centerX - detCx).abs() / math.max(track.width, 1.0);
        final dy = (track.centerY - detCy).abs() / math.max(track.height, 1.0);
        final dist = math.sqrt(dx * dx + dy * dy);
        final iou = _pairIoU(track, det);

        final areaRatio = track.area > 0.0 ? det.area / track.area : 1.0;
        // Allow up to 3.5x box growth when IoU is strong (>= 0.25) so sudden merged blobs associate and flag MERGED_BOX_SUSPECTED
        if (areaRatio < 0.45 || (areaRatio > 2.2 && iou < 0.25) || areaRatio > 3.5) {
          continue;
        }

        // RULE: A missing object cannot pass its track/denomination to a different-class or shifted object.
        if (track.framesMissing > 0) {
          if (det.isCoin) {
            if (det.classId != track.classId && iou < 0.45) continue;
            if (iou < 0.30 && dist > 0.35) continue;
          } else if (det.classId != track.classId || iou < 0.45) {
            continue;
          }
        }

        // RULE: Even on live frames, a sharp class change with low spatial overlap is a replacement object.
        if (det.classId != track.classId && iou < 0.35) {
          continue;
        }

        final bool compatible = det.isCoin
            ? (iou >= 0.20 || dist <= 0.32)
            : (iou >= 0.25 || (dist <= 0.42 && iou >= 0.05));
        if (!compatible) continue;

        final classBonus = (det.classId == track.classId) ? 0.35 : 0.0;
        final score = iou * 2.0 + (1.0 - dist.clamp(0.0, 1.0)) + classBonus;
        pairs.add(_PairCandidate(track: track, det: det, score: score, iou: iou, dist: dist));
      }
    }

    pairs.sort((a, b) => b.score.compareTo(a.score));

    final matchedTracks = <TrackedBanknote>{};
    final matchedDets = <CurrencyDetection>{};

    for (final p in pairs) {
      if (matchedTracks.contains(p.track) || matchedDets.contains(p.det)) continue;
      p.track.updateCandidate(p.det);
      matchedTracks.add(p.track);
      matchedDets.add(p.det);
    }

    // Decay missing tracks & retire replaced/expired tracks
    for (final track in _tracks) {
      if (!matchedTracks.contains(track)) {
        track.markMissing(candidateMode: true);
      }
    }

    final int beforeDrop = _tracks.length;
    final missingSnapshot = _tracks.where((t) => t.framesMissing > 0).toList();
    _tracks.removeWhere((t) => !t.shouldRetainCandidate);
    final int droppedStaleCount = beforeDrop - _tracks.length;

    // Spawn brand-new tracks for unmatched physical detections (and catch newly merged blobs covering vanishing notes)
    for (final det in sortedDets) {
      if (!matchedDets.contains(det)) {
        final newTrack = _createTrack(det);
        if (!det.isCoin) {
          for (final missing in missingSnapshot) {
            if (!missing.isCoin &&
                det.area > missing.area * 1.55 &&
                _pairIoMin(missing, det) > 0.65) {
              newTrack.suspectedMergeGrowth = true;
              break;
            }
          }
        }
        _tracks.add(newTrack);
      }
    }

    // Track-to-track overlap deduplication among currently visible (framesMissing == 0) tracks
    final dedupCount = _deduplicateActiveTracks();

    // Emit ONLY currently visible tracks (framesMissing == 0) for UI & monetary confirmation
    final activeDetections = _tracks
        .where((t) => t.framesMissing == 0)
        .map((t) => t.toDetection(candidateMode: true))
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    final int retainedMissingCount = _tracks.where((t) => t.framesMissing > 0).length;
    final combinedExtraReasons = <String>{...extraReasons};
    if (activeDetections.any((d) => d.uncertaintyReasons.contains('MERGED_BOX_SUSPECTED'))) {
      combinedExtraReasons.add('MERGED_BOX_SUSPECTED');
    }

    if (activeDetections.isEmpty) {
      _incompleteSceneCooldown = 0;
      _stableMultiBaselineCount = 0;
      _multiObjectStreak = 0;
      _cooldownTargetCount = 0;
    } else {
      final int activeCount = activeDetections.length;
      if (activeCount >= 2) {
        _multiObjectStreak++;
      } else {
        _multiObjectStreak = 0;
      }

      if (_incompleteSceneCooldown > 0) {
        if (activeCount >= _cooldownTargetCount) {
          _incompleteSceneCooldown = 0;
          _cooldownTargetCount = 0;
          _stableMultiBaselineCount = activeCount;
        } else {
          _incompleteSceneCooldown--;
          if (_incompleteSceneCooldown == 0) {
            _cooldownTargetCount = 0;
            if (_multiObjectStreak >= 2) {
              _stableMultiBaselineCount = activeCount;
            }
          }
        }
      } else if (_stableMultiBaselineCount >= 2 &&
          activeCount < _stableMultiBaselineCount) {
        _incompleteSceneCooldown = 4;
        _cooldownTargetCount = _stableMultiBaselineCount;
        _stableMultiBaselineCount = 0;
      } else if (_multiObjectStreak >= 2) {
        _stableMultiBaselineCount = activeCount;
      }

      if (_incompleteSceneCooldown > 0) {
        combinedExtraReasons.add('INCOMPLETE_SCENE');
      }
    }

    final assessment = CurrencySafetyEvaluator.evaluate(
      activeDetections,
      candidateMode: true,
      hasUncertainObjectCount:
          activeDetections.any((d) => d.uncertaintyReasons.contains('MERGED_BOX_SUSPECTED')) ||
              combinedExtraReasons.contains('INCOMPLETE_SCENE'),
      extraReasons: combinedExtraReasons,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );

    return TrackerUpdateResult(
      activeDetections: assessment.screenedDetections,
      assessment: assessment,
      activeTrackCount: activeDetections.length,
      retainedMissingCount: retainedMissingCount,
      droppedStaleCount: droppedStaleCount,
      deduplicatedTrackCount: dedupCount,
    );
  }

  int _deduplicateActiveTracks() {
    final visible = _tracks.where((t) => t.framesMissing == 0).toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final toRemove = <TrackedBanknote>{};

    for (int i = 0; i < visible.length; i++) {
      final keep = visible[i];
      if (toRemove.contains(keep)) continue;

      for (int j = i + 1; j < visible.length; j++) {
        final other = visible[j];
        if (toRemove.contains(other) || keep.isCoin != other.isCoin) continue;

        final iou = _trackIoU(keep, other);
        final iomin = _trackIoMin(keep, other);

        // Center-distance aware track deduplication: separate overlapping physical items from duplicate tracks
        final dx = (keep.centerX - other.centerX).abs();
        final dy = (keep.centerY - other.centerY).abs();
        final encW = math.max(keep.x2, other.x2) - math.min(keep.x1, other.x1);
        final encH = math.max(keep.y2, other.y2) - math.min(keep.y1, other.y1);
        final cDiag = math.sqrt(encW * encW + encH * encH);
        final normCenterDist = cDiag > 0.0 ? math.sqrt(dx * dx + dy * dy) / cDiag : 0.0;

        final bool shouldSuppress = (keep.isCoin)
            ? (normCenterDist < 0.22 && (iou > 0.55 || iomin > 0.78))
            : (normCenterDist < 0.18 && (iou > 0.65 || iomin > 0.82));

        if (shouldSuppress) {
          toRemove.add(other);
          if (other.classId != keep.classId &&
              other.confidence >= 0.35 &&
              (keep.confidence - other.confidence < 0.18)) {
            keep.suppressedConflictCount += 1;
            if (other.confidence > keep.suppressedConflictConfidence) {
              keep.suppressedConflictConfidence = other.confidence;
              keep.suppressedConflictClassId = other.classId;
              keep.suppressedConflictClassName = other.denomination;
            }
            if (!keep.rawUncertaintyReasons.contains('CROSS_CLASS_CONFLICT')) {
              keep.rawUncertaintyReasons = [
                ...keep.rawUncertaintyReasons,
                'CROSS_CLASS_CONFLICT',
              ];
            }
          }
        }
      }
    }

    if (toRemove.isNotEmpty) {
      _tracks.removeWhere((t) => toRemove.contains(t));
    }
    return toRemove.length;
  }

  TrackedBanknote _createTrack(CurrencyDetection det) {
    return TrackedBanknote(
      id: _nextId++,
      classId: det.classId,
      denomination: det.denomination,
      value: det.value,
      confidence: det.confidence,
      x1: det.x1,
      y1: det.y1,
      x2: det.x2,
      y2: det.y2,
      type: det.type,
      top2ClassId: det.top2ClassId,
      top2ClassName: det.top2ClassName,
      top2Confidence: det.top2Confidence,
      classMargin: det.classMargin,
      suppressedConflictCount: det.suppressedConflictCount,
      suppressedConflictClassId: det.suppressedConflictClassId,
      suppressedConflictClassName: det.suppressedConflictClassName,
      suppressedConflictConfidence: det.suppressedConflictConfidence,
      interBoxMaxIoU: det.interBoxMaxIoU,
      interBoxMaxIoMin: det.interBoxMaxIoMin,
      rawConfirmationState: det.confirmationState,
      rawUncertaintyReasons: List<String>.from(det.uncertaintyReasons),
    );
  }

  double _pairIoU(TrackedBanknote a, CurrencyDetection b) {
    final xx1 = math.max(a.x1, b.x1);
    final yy1 = math.max(a.y1, b.y1);
    final xx2 = math.min(a.x2, b.x2);
    final yy2 = math.min(a.y2, b.y2);
    final inter = math.max(0.0, xx2 - xx1) * math.max(0.0, yy2 - yy1);
    final union = a.area + b.area - inter;
    return union > 0.0 ? inter / union : 0.0;
  }

  double _pairIoMin(TrackedBanknote a, CurrencyDetection b) {
    final xx1 = math.max(a.x1, b.x1);
    final yy1 = math.max(a.y1, b.y1);
    final xx2 = math.min(a.x2, b.x2);
    final yy2 = math.min(a.y2, b.y2);
    final inter = math.max(0.0, xx2 - xx1) * math.max(0.0, yy2 - yy1);
    final minArea = math.min(a.area, b.area);
    return minArea > 0.0 ? inter / minArea : 0.0;
  }

  double _trackIoU(TrackedBanknote a, TrackedBanknote b) {
    final xx1 = math.max(a.x1, b.x1);
    final yy1 = math.max(a.y1, b.y1);
    final xx2 = math.min(a.x2, b.x2);
    final yy2 = math.min(a.y2, b.y2);
    final inter = math.max(0.0, xx2 - xx1) * math.max(0.0, yy2 - yy1);
    final union = a.area + b.area - inter;
    return union > 0.0 ? inter / union : 0.0;
  }

  double _trackIoMin(TrackedBanknote a, TrackedBanknote b) {
    final xx1 = math.max(a.x1, b.x1);
    final yy1 = math.max(a.y1, b.y1);
    final xx2 = math.min(a.x2, b.x2);
    final yy2 = math.min(a.y2, b.y2);
    final inter = math.max(0.0, xx2 - xx1) * math.max(0.0, yy2 - yy1);
    final minArea = math.min(a.area, b.area);
    return minArea > 0.0 ? inter / minArea : 0.0;
  }

  void reset() {
    _tracks.clear();
    _stableMultiBaselineCount = 0;
    _multiObjectStreak = 0;
    _cooldownTargetCount = 0;
    _incompleteSceneCooldown = 0;
  }
}
