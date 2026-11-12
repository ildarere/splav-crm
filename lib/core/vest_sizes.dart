import 'people_models.dart';

/// Russian paired sizes used for the trip's vest packing list. Raw measurements
/// stay on the participant; ranges spanning two buckets stay explicit.
String vestSize(Object? raw) {
  var s = (raw?.toString() ?? '')
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'РАЗМЕР|SIZE|РОССИЯ|RUS|RU'), '')
      .replaceAll('Х', 'X')
      .replaceAll('М', 'M')
      .replaceAll('Л', 'L')
      .replaceAll('С', 'S')
      .replaceAll(RegExp(r'[РР.\s()]'), '')
      .replaceAll(RegExp(r'[—–/]'), '-');
  if (s.isEmpty) return 'Не указан';
  s = s
      .replaceAll('2XL', 'XXL')
      .replaceAll('3XL', 'XXXL')
      .replaceAll('4XL', 'XXXXL');
  const pairs = {
    'XS': [40, 42],
    'S': [44, 46],
    'M': [48, 50],
    'L': [52, 54],
    'XL': [56, 58],
    'XXL': [60, 62],
    'XXXL': [64, 66],
    'XXXXL': [68, 70],
  };
  if (pairs.containsKey(s)) return s;
  final numbers = s.split('-').map(int.tryParse).toList();
  if (numbers.every((n) => n != null) && numbers.isNotEmpty) {
    for (final e in pairs.entries) {
      if (numbers.every((n) => e.value.contains(n))) return e.key;
    }
  }
  return s;
}

const vestSizeGuide =
    'Размеры РФ: XS 40–42 · S 44–46 · M 48–50 · L 52–54 · XL 56–58 · XXL 60–62 · XXXL 64–66. Диапазоны между разными размерами не объединяются.';
JsonMap normalizedParameters(JsonMap raw) => {
  ...raw,
  if (raw['clothing_size'] != null &&
      raw['clothing_size'].toString().trim().isNotEmpty)
    'clothing_size': vestSize(raw['clothing_size']),
};
