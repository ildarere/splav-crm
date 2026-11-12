import 'package:flutter/material.dart';

const instructorColor = Color(0xffffcf32);

class InstructorMark extends StatelessWidget {
  const InstructorMark({super.key, this.size = 26});
  final double size;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Инструктор',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.asset(
        'assets/logo.jpg',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    ),
  );
}
