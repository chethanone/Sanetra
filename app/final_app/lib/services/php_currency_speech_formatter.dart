import 'bisaya_number_normalizer.dart';
import 'currency_region.dart';
import 'currency_safety_evaluator.dart';

/// Independent Philippine Peso (`CurrencyRegion.php`) currency speech formatter
/// in Cebuano (Bisaya) using exact integer **sentimo** arithmetic
/// (`100 sentimo = ₱1.00`).
///
/// Never reuses Indian Rupee (`₹`) wording or floating-point totals.
class PhpCurrencySpeechFormatter {
  const PhpCurrencySpeechFormatter._();

  /// Format an integer [totalSentimo] amount into Cebuano peso/sentimo words.
  ///
  /// Examples:
  /// - `25` -> `"kawhaan ug lima ka sentimo"`
  /// - `100` -> `"usa ka piso"`
  /// - `125` -> `"usa ka piso ug kawhaan ug lima ka sentimo"`
  /// - `250` -> `"duha ka piso ug kalim-an ka sentimo"`
  /// - `1000` -> `"napulo ka piso"`
  static String formatSentimoAmountCebuano(int totalSentimo) {
    if (totalSentimo <= 0) return 'wala ka piso';
    final pesos = totalSentimo ~/ 100;
    final sentimo = totalSentimo % 100;
    if (pesos == 0) {
      return '${BisayaNumberNormalizer.numberToCebuanoWords(sentimo)} ka sentimo';
    }
    final pesoPart =
        '${BisayaNumberNormalizer.numberToCebuanoWords(pesos)} ka piso';
    if (sentimo == 0) return pesoPart;
    return '$pesoPart ug ${BisayaNumberNormalizer.numberToCebuanoWords(sentimo)} ka sentimo';
  }

  /// Format a display string like `₱1.25` or `₱500` using integer sentimo math.
  static String formatPesoDisplay(int totalSentimo) {
    final pesos = totalSentimo ~/ 100;
    final sentimo = totalSentimo % 100;
    if (sentimo == 0) return '₱$pesos';
    final sStr = sentimo.toString().padLeft(2, '0');
    return '₱$pesos.$sStr';
  }

  /// Format a single grouped Philippine currency item in Cebuano.
  static String formatPhpGroup(String denomination, int count) {
    final upper = denomination.toUpperCase();
    final sentimo = kPhpSentimoValues[upper] ?? 0;
    final countWords = BisayaNumberNormalizer.numberToCebuanoWords(count);

    if (upper == 'PHP_OLD_DEMONETIZED') {
      return 'karaang kwarta nga dili na magamit';
    }
    if (upper.startsWith('PHP_COIN_')) {
      final amountWords = formatSentimoAmountCebuano(sentimo);
      return '$countWords ka $amountWords nga sensilyo';
    }
    if (upper.startsWith('PHP_POLYMER_')) {
      final amountWords = formatSentimoAmountCebuano(sentimo);
      return '$countWords ka $amountWords nga polymer nga papel';
    }
    final amountWords = formatSentimoAmountCebuano(sentimo);
    return '$countWords ka $amountWords nga papel';
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _joinList(List<String> items) {
    if (items.isEmpty) return '';
    if (items.length == 1) return items.first;
    if (items.length == 2) return '${items[0]} ug ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(', ')}, ug ${items.last}';
  }

  /// Format a PHP [assessment] strictly using [kPhpDenominationAllowlist] and
  /// integer sentimo totals.
  ///
  /// - Rejects any non-PHP detections (e.g. INR notes/coins).
  /// - Excludes `PHP_OLD_DEMONETIZED` from the spendable total and appends a
  ///   clear Cebuano warning.
  /// - Never speaks a confirmed total when assessment is uncertain or tentative.
  static String formatAssessmentPhp(
    CurrencySafetyAssessment assessment, {
    bool hadForeignRejected = false,
  }) {
    final phpOnly = filterDetectionsForRegion(
      assessment.screenedDetections,
      CurrencyRegion.php,
    );

    if (phpOnly.isEmpty) {
      if (hadForeignRejected ||
          assessment.screenedDetections.isNotEmpty) {
        return 'Dili kini kwarta sa Pilipinas. Palihug ipakita ang kwarta nga piso.';
      }
      if (assessment.status == AnnouncementSafetyStatus.conflictingOrUncertain) {
        return 'Dili sigurado ang kantidad sa kwarta. Palihug usba ang suga o anggulo ug sulayi pag-usab.';
      }
      return 'Walay kwarta sa Pilipinas nga nakita. Palihug ipaduol pa gamay.';
    }

    if (assessment.status == AnnouncementSafetyStatus.conflictingOrUncertain) {
      if (assessment.reasons.contains('MERGED_BOX_SUSPECTED') ||
          assessment.reasons.contains('UNCERTAIN_COUNT')) {
        return 'Dili klaro o nagpatong ang mga kwarta. Palihug ibulag kini ug sulayi pag-usab.';
      }
      return 'Dili sigurado ang kantidad sa kwarta. Palihug usba ang suga o anggulo ug sulayi pag-usab.';
    }

    final demonetized = phpOnly
        .where((d) => d.denomination.toUpperCase() == 'PHP_OLD_DEMONETIZED')
        .toList();
    final spendable = phpOnly
        .where((d) => d.denomination.toUpperCase() != 'PHP_OLD_DEMONETIZED')
        .toList();

    if (spendable.isEmpty && demonetized.isNotEmpty) {
      return 'Pahimangno: karaang papel nga kwarta nga dili na magamit. Wala kini giapil sa kinatibuk-an.';
    }

    if (assessment.status == AnnouncementSafetyStatus.tentativeSingle) {
      final d = spendable.first;
      final item = formatPhpGroup(d.denomination, 1);
      return 'Posibleng $item, apan dili pa kumpirmado. Hupti og tarong sa hayag nga suga ug sulayi pag-usab.';
    }

    // Aggregate spendable counts by internal class (paper and polymer kept
    // distinct for naming, summed once in integer sentimo so never double-counted)
    final counts = <String, int>{};
    int totalSentimo = 0;
    for (final d in spendable) {
      final key = d.denomination.toUpperCase();
      counts[key] = (counts[key] ?? 0) + 1;
      totalSentimo += kPhpSentimoValues[key] ?? 0;
    }

    final parts = <String>[];
    counts.forEach((denom, count) {
      parts.add(formatPhpGroup(denom, count));
    });

    final String base;
    if (spendable.length == 1) {
      base = '${_capitalize(parts.first)}.';
    } else {
      final totalWords = formatSentimoAmountCebuano(totalSentimo);
      base = '${_capitalize(_joinList(parts))}. Kinatibuk-an, $totalWords.';
    }

    if (demonetized.isNotEmpty) {
      return '$base Pahimangno: may karaang kwarta nga dili na magamit ug wala giapil sa kinatibuk-an.';
    }
    return base;
  }
}
