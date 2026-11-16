import 'currency_model_service.dart';
import 'currency_safety_evaluator.dart';

/// Pure-Cebuano (Bisaya) number-to-words normalizer and currency speech
/// formatter for `ceb-PH`.
///
/// Avoids Filipino/Tagalog substitutions and never emits raw numeric digits so
/// character-vocabulary VITS synthesis (`facebook/mms-tts-ceb`) pronounces
/// counts, Indian Rupee denominations, and totals naturally.
class BisayaNumberNormalizer {
  const BisayaNumberNormalizer._();

  static const List<String> _units = [
    'wala',
    'usa',
    'duha',
    'tulo',
    'upat',
    'lima',
    'unom',
    'pito',
    'walo',
    'siyam',
    'napulo',
  ];

  static const List<String> _tens = [
    '',
    'napulo',
    'kawhaan',
    'katloan',
    'kap-atan',
    'kalim-an',
    'kan-uman',
    'kapitoan',
    'kawaloan',
    'kasiyaman',
  ];

  /// Convert a non-negative integer [n] (`0..999,999`) into Cebuano words.
  static String numberToCebuanoWords(int n) {
    if (n < 0) return 'menos ${numberToCebuanoWords(-n)}';
    if (n <= 10) return _units[n];
    if (n < 20) {
      return "napulo'g ${_units[n - 10]}";
    }
    if (n < 100) {
      final t = n ~/ 10;
      final u = n % 10;
      return u == 0 ? _tens[t] : '${_tens[t]} ug ${_units[u]}';
    }
    if (n < 1000) {
      final h = n ~/ 100;
      final rem = n % 100;
      final hPart = '${_units[h]} ka gatos';
      return rem == 0 ? hPart : '$hPart ug ${numberToCebuanoWords(rem)}';
    }
    if (n < 1000000) {
      final k = n ~/ 1000;
      final rem = n % 1000;
      final kPart = '${numberToCebuanoWords(k)} ka libo';
      return rem == 0 ? kPart : '$kPart ug ${numberToCebuanoWords(rem)}';
    }
    return n.toString();
  }

  /// Format a single grouped Indian Rupee denomination in Cebuano, e.g.
  /// `(INR_200, 200, 2)` -> `"duha ka duha ka gatos ka rupee nga papel"`.
  static String formatBisayaGroup(String denomination, int value, int count) {
    final bool isCoin = denomination.toUpperCase().contains('COIN');
    final String countWords = numberToCebuanoWords(count);
    final String denomWords = numberToCebuanoWords(value);
    final String unit = isCoin ? 'sensilyo' : 'papel';
    return '$countWords ka $denomWords ka rupee nga $unit';
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  static String _joinBisayaList(List<String> items) {
    if (items.isEmpty) return '';
    if (items.length == 1) return items.first;
    if (items.length == 2) return '${items[0]} ug ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(', ')}, ug ${items.last}';
  }

  static ({Map<String, int> counts, Map<String, int> values}) _aggregate(
    List<CurrencyDetection> detections,
  ) {
    final counts = <String, int>{};
    final values = <String, int>{};
    for (final d in detections) {
      counts[d.denomination] = (counts[d.denomination] ?? 0) + 1;
      values[d.denomination] = d.value;
    }
    return (counts: counts, values: values);
  }

  /// Format [assessment] into natural Cebuano (Bisaya) currency speech.
  static String formatAssessmentBisaya(CurrencySafetyAssessment assessment) {
    switch (assessment.status) {
      case AnnouncementSafetyStatus.empty:
        return 'Walay kwarta nga nakita. Palihug ipaduol pa gamay.';
      case AnnouncementSafetyStatus.conflictingOrUncertain:
        if (assessment.reasons.contains('MERGED_BOX_SUSPECTED') ||
            assessment.reasons.contains('UNCERTAIN_COUNT')) {
          return 'Dili klaro o nagpatong ang mga kwarta. Palihug ibulag kini ug sulayi pag-usab.';
        }
        return 'Nagkasumpaki ang kantidad sa kwarta. Palihug usba ang suga o anggulo ug sulayi pag-usab.';
      case AnnouncementSafetyStatus.tentativeSingle:
        final d = assessment.screenedDetections.first;
        final item = formatBisayaGroup(d.denomination, d.value, 1);
        return 'Posibleng $item, apan dili pa kumpirmado. Hupti og tarong sa hayag nga suga ug sulayi pag-usab.';
      case AnnouncementSafetyStatus.confirmedSingle:
        final d = assessment.screenedDetections.first;
        return '${_capitalize(formatBisayaGroup(d.denomination, d.value, 1))}.';
      case AnnouncementSafetyStatus.confirmedMultiple:
        final agg = _aggregate(assessment.screenedDetections);
        final parts = <String>[];
        agg.counts.forEach((denom, count) {
          final val = agg.values[denom] ?? 0;
          parts.add(formatBisayaGroup(denom, val, count));
        });
        final total =
            assessment.confirmedTotalRupees ?? assessment.visibleDetectedSumRupees;
        final totalWords = numberToCebuanoWords(total);
        return '${_capitalize(_joinBisayaList(parts))}. Kinatibuk-an, $totalWords ka rupee.';
    }
  }
}
