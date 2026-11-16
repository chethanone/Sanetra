import 'currency_safety_evaluator.dart';

/// Converts integer rupee amounts and currency safety assessments into natural,
/// grammatically correct Kannada words for offline Kannada TTS.
class KannadaNumberNormalizer {
  const KannadaNumberNormalizer._();

  static const List<String> _units = [
    'ಸೊನ್ನೆ',
    'ಒಂದು',
    'ಎರಡು',
    'ಮೂರು',
    'ನಾಲ್ಕು',
    'ಐದು',
    'ಆರು',
    'ಏಳು',
    'ಎಂಟು',
    'ಒಂಬತ್ತು',
    'ಹತ್ತು',
    'ಹನ್ನೊಂದು',
    'ಹನ್ನೆರಡು',
    'ಹದಿಮೂರು',
    'ಹದಿನಾಲ್ಕು',
    'ಹದಿನೈದು',
    'ಹದಿನಾರು',
    'ಹದಿನೇಳು',
    'ಹದಿನೆಂಟು',
    'ಹತ್ತೊಂಬತ್ತು',
  ];

  static const Map<int, String> _tens = {
    20: 'ಇಪ್ಪತ್ತು',
    30: 'ಮೂವತ್ತು',
    40: 'ನಲವತ್ತು',
    50: 'ಐವತ್ತು',
    60: 'ಅರವತ್ತು',
    70: 'ಎಪ್ಪತ್ತು',
    80: 'ಎಂಬತ್ತು',
    90: 'ತೊಂಬತ್ತು',
  };

  /// Compound stems for 21..99 when followed by a unit digit (1..9).
  static const Map<int, String> _tensStem = {
    20: 'ಇಪ್ಪತ್ತ',
    30: 'ಮೂವತ್ತ',
    40: 'ನಲವತ್ತ',
    50: 'ಐವತ್ತ',
    60: 'ಅರವತ್ತ',
    70: 'ಎಪ್ಪತ್ತ',
    80: 'ಎಂಬತ್ತ',
    90: 'ತೊಂಬತ್ತ',
  };

  /// Unit forms used after tens stem (21..99).
  static const List<String> _compoundUnits = [
    '',
    'ಒಂದು',
    'ಎರಡು',
    'ಮೂರು',
    'ನಾಲ್ಕು',
    'ಐದು',
    'ಆರು',
    'ಏಳು',
    'ಎಂಟು',
    'ಒಂಬತ್ತು',
  ];

  static const Map<int, String> _hundreds = {
    1: 'ನೂರು',
    2: 'ಇನ್ನೂರು',
    3: 'ಮುನ್ನೂರು',
    4: 'ನಾಲ್ಕು ನೂರು',
    5: 'ಐದು ನೂರು',
    6: 'ಆರು ನೂರು',
    7: 'ಎಳು ನೂರು',
    8: 'ಎಂಟು ನೂರು',
    9: 'ಒಂಬತ್ತು ನೂರು',
  };

  /// Convert a non-negative integer [n] (up to 9,99,999) into natural Kannada words.
  static String numberToKannadaWords(int n) {
    if (n < 0) return 'ಋಣ ${numberToKannadaWords(-n)}';
    if (n < 20) return _units[n];
    if (n < 100) {
      final t = (n ~/ 10) * 10;
      final u = n % 10;
      if (u == 0) return _tens[t]!;
      return '${_tensStem[t]}${_compoundUnits[u]}';
    }
    if (n < 1000) {
      final h = n ~/ 100;
      final rem = n % 100;
      if (rem == 0) return _hundreds[h]!;
      final hPrefix = h == 1 ? 'ನೂರಾ' : '${_hundreds[h]}';
      return '$hPrefix ${numberToKannadaWords(rem)}';
    }
    if (n < 100000) {
      final k = n ~/ 1000;
      final rem = n % 1000;
      final kWord = k == 1 ? 'ಒಂದು ಸಾವಿರ' : '${numberToKannadaWords(k)} ಸಾವಿರ';
      if (rem == 0) return kWord;
      return '$kWord ${numberToKannadaWords(rem)}';
    }
    final lakh = n ~/ 100000;
    final rem = n % 100000;
    final lWord = lakh == 1 ? 'ಒಂದು ಲಕ್ಷ' : '${numberToKannadaWords(lakh)} ಲಕ್ಷ';
    if (rem == 0) return lWord;
    return '$lWord ${numberToKannadaWords(rem)}';
  }

  /// Format a single currency item (note or coin) in natural Kannada.
  static String formatItemKannada(String denomination, int value) {
    final amountWords = numberToKannadaWords(value);
    if (denomination.toUpperCase().contains('COIN')) {
      return '$amountWords ರೂಪಾಯಿ ನಾಣ್ಯ';
    }
    return '$amountWords ರೂಪಾಯಿ ನೋಟು';
  }

  /// Format a rupee total in natural Kannada, e.g. 27 -> "ಇಪ್ಪತ್ತೇಳು ರೂಪಾಯಿ".
  static String formatTotalKannada(int totalRupees) {
    return '${numberToKannadaWords(totalRupees)} ರೂಪಾಯಿ';
  }

  /// Build natural Kannada speech for a [CurrencySafetyAssessment] without
  /// modifying any underlying currency detection or safety logic.
  static String formatAssessmentKannada(CurrencySafetyAssessment assessment) {
    switch (assessment.status) {
      case AnnouncementSafetyStatus.empty:
        return 'ಹಣ ಕಂಡುಬಂದಿಲ್ಲ. ದಯವಿಟ್ಟು ಹತ್ತಿರ ಹಿಡಿಯಿರಿ.';
      case AnnouncementSafetyStatus.conflictingOrUncertain:
        if (assessment.reasons.contains('MERGED_BOX_SUSPECTED') ||
            assessment.reasons.contains('UNCERTAIN_COUNT')) {
          return 'ಕೆಲವು ನೋಟುಗಳು ಸ್ಪಷ್ಟವಾಗಿಲ್ಲ ಅಥವಾ ಒಂದರ ಮೇಲೊಂದು ಇವೆ. ದಯವಿಟ್ಟು ಬೇರ್ಪಡಿಸಿ ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.';
        }
        return 'ಮೌಲ್ಯ ಸ್ಪಷ್ಟವಾಗಿಲ್ಲ. ದಯವಿಟ್ಟು ಬೆಳಕು ಅಥವಾ ಕೋನವನ್ನು ಸರಿಪಡಿಸಿ ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.';
      case AnnouncementSafetyStatus.tentativeSingle:
        final d = assessment.screenedDetections.first;
        return 'ಬಹುಶಃ ${formatItemKannada(d.denomination, d.value)}. ದೃಢೀಕರಿಸಲು ಸ್ಥಿರವಾಗಿ ಹಿಡಿಯಿರಿ.';
      case AnnouncementSafetyStatus.confirmedSingle:
        final d = assessment.screenedDetections.first;
        return formatItemKannada(d.denomination, d.value);
      case AnnouncementSafetyStatus.confirmedMultiple:
        final counts = <String, int>{};
        final values = <String, int>{};
        for (final d in assessment.screenedDetections) {
          counts[d.denomination] = (counts[d.denomination] ?? 0) + 1;
          values[d.denomination] = d.value;
        }
        final parts = <String>[];
        counts.forEach((denom, count) {
          final val = values[denom] ?? 0;
          if (count == 1) {
            parts.add(formatItemKannada(denom, val));
          } else {
            parts.add('${numberToKannadaWords(count)} ${formatItemKannada(denom, val)}ಗಳು');
          }
        });
        final total = assessment.confirmedTotalRupees ?? assessment.visibleDetectedSumRupees;
        return '${parts.join(', ')}. ಒಟ್ಟು ${formatTotalKannada(total)}.';
    }
  }
}
