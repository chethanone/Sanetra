/// Normalizes and expands currency and mathematical symbols into natural spoken
/// words for Text-To-Speech (TTS) across English (`en-IN`), Hindi (`hi-IN`),
/// and Kannada (`kn-IN`).
class OcrSymbolNormalizer {
  /// Checks whether a character rune represents a supported currency, math, or packaging symbol.
  static bool isSymbolRune(int rune) {
    return (rune >= 0x0021 && rune <= 0x002F) || // ! " # $ % & ' ( ) * + , - . /
        (rune >= 0x003A && rune <= 0x0040) || // : ; < = > ? @
        (rune >= 0x005B && rune <= 0x0060) || // [ \ ] ^ _ `
        (rune >= 0x007B && rune <= 0x007E) || // { | } ~
        (rune >= 0x00A0 && rune <= 0x00BF) || // Latin-1 symbols (£, ¥, §, ©, ®, °, ±, µ, etc.)
        rune == 0x00D7 || rune == 0x00F7 || // ×, ÷
        (rune >= 0x20A0 && rune <= 0x20CF) || // Currency symbols (₹, €, ₿, etc.)
        (rune >= 0x2100 && rune <= 0x214F) || // Letterlike symbols (№, ℃, ℉, ℞, Ω, etc.)
        (rune >= 0x2200 && rune <= 0x22FF) || // Math operators (±, ×, ÷, √, ∞, etc.)
        (rune >= 0x2700 && rune <= 0x27BF); // Dingbats / checkmarks (✓, ✔, ✗, ✘)
  }

  /// Expands currency, math, unit, and everyday symbols into natural spoken language
  /// for TTS pronunciation so visually impaired users hear "500 Rupees" instead of
  /// an inaudible or mangled symbol.
  static String expandForSpeech(String text, String language) {
    if (text.trim().isEmpty) return text;

    String s = text;

    if (language == 'kn-IN') {
      // 1. Currency with amount
      s = s.replaceAllMapped(RegExp(r'(?:₹|Rs\.?|INR)\s*(\d+(?:\.\d+)?)', caseSensitive: false), (m) => '${m[1]} ರೂಪಾಯಿ');
      s = s.replaceAllMapped(RegExp(r'\$\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} ಡಾಲರ್');
      s = s.replaceAllMapped(RegExp(r'€\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} ಯೂರೋ');
      s = s.replaceAllMapped(RegExp(r'£\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} ಪೌಂಡ್');
      s = s.replaceAllMapped(RegExp(r'¥\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} ಯೆನ್');
      s = s.replaceAllMapped(RegExp(r'¢\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} ಸೆಂಟ್ಸ್');

      // Standalone currency symbols
      s = s.replaceAll('₹', ' ರೂಪಾಯಿ ');
      s = s.replaceAll(RegExp(r'\bRs\.?\b', caseSensitive: false), ' ರೂಪಾಯಿ ');
      s = s.replaceAll('\$', ' ಡಾಲರ್ ');
      s = s.replaceAll('€', ' ಯೂರೋ ');
      s = s.replaceAll('£', ' ಪೌಂಡ್ ');
      s = s.replaceAll('¥', ' ಯೆನ್ ');
      s = s.replaceAll('¢', ' ಸೆಂಟ್ಸ್ ');

      // Percentage & temperatures
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*%'), (m) => '${m[1]} ಪ್ರತಿಶತ');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(?:°C|℃)'), (m) => '${m[1]} ಡಿಗ್ರಿ ಸೆಲ್ಸಿಯಸ್');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(?:°F|℉)'), (m) => '${m[1]} ಡಿಗ್ರಿ ಫ್ಯಾರನ್‌ಹೀಟ್');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*°'), (m) => '${m[1]} ಡಿಗ್ರಿ');
      s = s.replaceAll('%', ' ಪ್ರತಿಶತ ');

      // Medical & Packaging
      s = s.replaceAll(RegExp(r'\b(?:Rx|℞)\b', caseSensitive: false), ' ವೈದ್ಯಕೀಯ ಚೀಟಿ ');
      s = s.replaceAll('℞', ' ವೈದ್ಯಕೀಯ ಚೀಟಿ ');
      s = s.replaceAll(RegExp(r'\b(?:№|No\.)\s*(\d+)', caseSensitive: false), r' ಸಂಖ್ಯೆ $1 ');
      s = s.replaceAll('№', ' ಸಂಖ್ಯೆ ');

      // Math & symbols
      s = s.replaceAll(' + ', ' ಪ್ಲಸ್ ');
      s = s.replaceAll(' = ', ' ಸಮಾನ ');
      s = s.replaceAll(' ± ', ' ಪ್ಲಸ್ ಅಥವಾ ಮೈನಸ್ ');
      s = s.replaceAll(RegExp(r'(\d+)\s*[xX×]\s*(\d+)'), r'$1 ಗುಣಿಸು $2');
      s = s.replaceAll(' & ', ' ಮತ್ತು ');
      s = s.replaceAll(' @ ', ' ಅಟ್ ');
      s = s.replaceAll(RegExp(r'[✓✔]'), ' ಸರಿ ');
      s = s.replaceAll(RegExp(r'[✗✘]'), ' ತಪ್ಪು ');
      s = s.replaceAll('©', ' ಕೃತಿಸ್ವಾಮ್ಯ ');
      s = s.replaceAll('®', ' ನೋಂದಾಯಿತ ');
      s = s.replaceAll('™', ' ಟ್ರೇಡ್‌ಮಾರ್ಕ್ ');
    } else if (language == 'hi-IN') {
      // 1. Currency with amount
      s = s.replaceAllMapped(RegExp(r'(?:₹|Rs\.?|INR)\s*(\d+(?:\.\d+)?)', caseSensitive: false), (m) => '${m[1]} रुपये');
      s = s.replaceAllMapped(RegExp(r'\$\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} डॉलर');
      s = s.replaceAllMapped(RegExp(r'€\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} यूरो');
      s = s.replaceAllMapped(RegExp(r'£\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} पाउंड');
      s = s.replaceAllMapped(RegExp(r'¥\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} येन');
      s = s.replaceAllMapped(RegExp(r'¢\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} सेंट्स');

      // Standalone currency symbols
      s = s.replaceAll('₹', ' रुपये ');
      s = s.replaceAll(RegExp(r'\bRs\.?\b', caseSensitive: false), ' रुपये ');
      s = s.replaceAll('\$', ' डॉलर ');
      s = s.replaceAll('€', ' यूरो ');
      s = s.replaceAll('£', ' पाउंड ');
      s = s.replaceAll('¥', ' येन ');
      s = s.replaceAll('¢', ' सेंट्स ');

      // Percentage & temperatures
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*%'), (m) => '${m[1]} प्रतिशत');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(?:°C|℃)'), (m) => '${m[1]} डिग्री सेल्सियस');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(?:°F|℉)'), (m) => '${m[1]} डिग्री फारेनहाइट');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*°'), (m) => '${m[1]} डिग्री');
      s = s.replaceAll('%', ' प्रतिशत ');

      // Medical & Packaging
      s = s.replaceAll(RegExp(r'\b(?:Rx|℞)\b', caseSensitive: false), ' प्रिस्क्रिप्शन ');
      s = s.replaceAll('℞', ' प्रिस्क्रिप्शन ');
      s = s.replaceAll(RegExp(r'\b(?:№|No\.)\s*(\d+)', caseSensitive: false), r' नंबर $1 ');
      s = s.replaceAll('№', ' नंबर ');

      // Math & symbols
      s = s.replaceAll(' + ', ' प्लस ');
      s = s.replaceAll(' = ', ' बराबर ');
      s = s.replaceAll(' ± ', ' प्लस माइनस ');
      s = s.replaceAll(RegExp(r'(\d+)\s*[xX×]\s*(\d+)'), r'$1 गुणा $2');
      s = s.replaceAll(' & ', ' और ');
      s = s.replaceAll(' @ ', ' एट ');
      s = s.replaceAll(RegExp(r'[✓✔]'), ' सही ');
      s = s.replaceAll(RegExp(r'[✗✘]'), ' गलत ');
      s = s.replaceAll('©', ' कॉपीराइट ');
      s = s.replaceAll('®', ' पंजीकृत ');
      s = s.replaceAll('™', ' ट्रेडमार्क ');
    } else {
      // English (en-IN / default)
      // 1. Currency with amount
      s = s.replaceAllMapped(RegExp(r'(?:₹|Rs\.?|INR)\s*(\d+(?:\.\d+)?)', caseSensitive: false), (m) => '${m[1]} Rupees');
      s = s.replaceAllMapped(RegExp(r'\$\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} Dollars');
      s = s.replaceAllMapped(RegExp(r'€\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} Euros');
      s = s.replaceAllMapped(RegExp(r'£\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} Pounds');
      s = s.replaceAllMapped(RegExp(r'¥\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} Yen');
      s = s.replaceAllMapped(RegExp(r'¢\s*(\d+(?:\.\d+)?)'), (m) => '${m[1]} cents');

      // Standalone currency symbols
      s = s.replaceAll('₹', ' Rupees ');
      s = s.replaceAll(RegExp(r'\bRs\.?\b', caseSensitive: false), ' Rupees ');
      s = s.replaceAll('\$', ' Dollars ');
      s = s.replaceAll('€', ' Euros ');
      s = s.replaceAll('£', ' Pounds ');
      s = s.replaceAll('¥', ' Yen ');
      s = s.replaceAll('¢', ' cents ');

      // Percentage & temperatures
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*%'), (m) => '${m[1]} percent');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(?:°C|℃)'), (m) => '${m[1]} degrees Celsius');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(?:°F|℉)'), (m) => '${m[1]} degrees Fahrenheit');
      s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*°'), (m) => '${m[1]} degrees');
      s = s.replaceAll('%', ' percent ');

      // Medical & Packaging
      s = s.replaceAll(RegExp(r'\b(?:Rx|℞)\b', caseSensitive: false), ' Prescription ');
      s = s.replaceAll('℞', ' Prescription ');
      s = s.replaceAll(RegExp(r'\b(?:№|No\.)\s*(\d+)', caseSensitive: false), r' Number $1 ');
      s = s.replaceAll('№', ' Number ');

      // Math & symbols
      s = s.replaceAll(' + ', ' plus ');
      s = s.replaceAll(' = ', ' equals ');
      s = s.replaceAll(' ± ', ' plus or minus ');
      s = s.replaceAll(RegExp(r'(\d+)\s*[xX×]\s*(\d+)'), r'$1 times $2');
      s = s.replaceAll(' & ', ' and ');
      s = s.replaceAll(' @ ', ' at ');
      s = s.replaceAll(RegExp(r'[✓✔]'), ' Checked ');
      s = s.replaceAll(RegExp(r'[✗✘]'), ' Cross ');
      s = s.replaceAll('©', ' Copyright ');
      s = s.replaceAll('®', ' Registered ');
      s = s.replaceAll('™', ' Trademark ');
    }

    // Collapse extra whitespaces cleanly
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
