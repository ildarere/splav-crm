import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:splav/features/bookings/company_import.dart';
import 'package:splav/core/input_formatters.dart';

void main() {
  test('Company examples preserve names and extract parameters', () {
    final rows = parseCompany('''Мартынов Александр Сергеевич 50р, 90 кг, 170
Мартынова Евгения Александровна - 44р, 55 кг, 160 (17 лет)
Коляда Елена - М
Савинов Александр - XL
Савинов Иван - 9 лет, 152 см, 34 кг
Кухалашвили Кирилл - 52''');
    expect(rows.length, 6);
    expect(rows[0].name, 'Мартынов Александр Сергеевич');
    expect(rows[0].parameters, {
      'clothing_size': '50',
      'weight_kg': 90,
      'height_cm': 170,
    });
    expect(rows[1].parameters['age_years'], 17);
    expect(rows[2].parameters['clothing_size'], 'M');
    expect(rows[3].parameters['clothing_size'], 'XL');
    expect(rows[4].parameters, {
      'age_years': 9,
      'height_cm': 152,
      'weight_kg': 34,
    });
    expect(rows[5].parameters['clothing_size'], '52');
  });
  test('Date and phone masks format pasted and incremental input', () {
    TextEditingValue value(String s) => TextEditingValue(
      text: s,
      selection: TextSelection.collapsed(offset: s.length),
    );
    final phone = DigitMask('+7 (###) ###-##-##');
    expect(
      phone.formatEditUpdate(value(''), value('89012345678')).text,
      '+7 (901) 234-56-78',
    );
    expect(
      phone.formatEditUpdate(value('+7 (9'), value('+7 (90')).text,
      '+7 (90',
    );
    expect(
      DigitMask(
        '##.##.####',
      ).formatEditUpdate(value(''), value('07062026')).text,
      '07.06.2026',
    );
  });
}
