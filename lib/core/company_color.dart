import 'package:flutter/material.dart';

Color companyColor(String id) {
  var hash = 0;
  for (final c in id.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  return Colors.primaries[hash % Colors.primaries.length].shade100;
}
