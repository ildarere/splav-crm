import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import '../../core/trip_dates.dart';
import 'trip_presentation.dart';

class TripCalendar extends StatefulWidget {
  const TripCalendar({
    super.key,
    required this.trips,
    required this.controller,
    required this.onOpen,
    required this.today,
    this.initialDay,
  });
  final List<Trip> trips;
  final Stage1Controller controller;
  final ValueChanged<Trip> onOpen;
  final DateTime today;
  final DateTime? initialDay;
  @override
  State<TripCalendar> createState() => _TripCalendarState();
}

class _TripCalendarState extends State<TripCalendar> {
  late DateTime _anchor =
      widget.initialDay ??
      DateTime(widget.today.year, widget.today.month, widget.today.day);
  bool? _week;
  void _move(int direction, bool week) => setState(
    () => _anchor = week
        ? _anchor.add(Duration(days: direction * 7))
        : DateTime(_anchor.year, _anchor.month + direction, 1),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final week = _week ?? constraints.maxWidth < 700;
      final monday = _anchor.subtract(Duration(days: _anchor.weekday - 1));
      final month = DateTime(_anchor.year, _anchor.month, 1);
      final first = week
          ? monday
          : month.subtract(Duration(days: month.weekday - 1));
      final days = week
          ? 7
          : ((month.weekday -
                        1 +
                        DateTime(month.year, month.month + 1, 0).day +
                        6) ~/
                    7) *
                7;
      const months = [
        'Январь',
        'Февраль',
        'Март',
        'Апрель',
        'Май',
        'Июнь',
        'Июль',
        'Август',
        'Сентябрь',
        'Октябрь',
        'Ноябрь',
        'Декабрь',
      ];
      final width = constraints.maxWidth.clamp(700, double.infinity);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              Text(
                week
                    ? '${first.day}.${first.month} — ${first.add(const Duration(days: 6)).day}.${first.add(const Duration(days: 6)).month} · ${_anchor.year}'
                    : '${months[_anchor.month - 1]} ${_anchor.year}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 8,
                children: [
                  IconButton(
                    tooltip: 'Предыдущий период',
                    onPressed: () => _move(-1, week),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _anchor = widget.today),
                    child: const Text('Сегодня'),
                  ),
                  IconButton(
                    tooltip: 'Следующий период',
                    onPressed: () => _move(1, week),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  ChoiceChip(
                    label: const Text('Месяц'),
                    selected: !week,
                    onSelected: (_) => setState(() => _week = false),
                  ),
                  ChoiceChip(
                    label: const Text('Неделя'),
                    selected: week,
                    onSelected: (_) => setState(() => _week = true),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width.toDouble(),
              child: Column(
                children: [
                  Row(
                    children: [
                      for (final name in [
                        'ПН',
                        'ВТ',
                        'СР',
                        'ЧТ',
                        'ПТ',
                        'СБ',
                        'ВС',
                      ])
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              name,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xff577082),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  for (var row = 0; row < days ~/ 7; row++)
                    _weekRow(first.add(Duration(days: row * 7))),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
  Widget _weekRow(DateTime first) {
    final last = first.add(const Duration(days: 6));
    final scaler = MediaQuery.textScalerOf(context);
    final eventHeight = math.max(
      70.0,
      24 + (2 * scaler.scale(13) + scaler.scale(12)) * 1.4,
    );
    final laneHeight = eventHeight + 4;
    final events =
        widget.trips.where((t) => overlapsDays(t, first, last)).toList()
          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final lanes = <List<Trip>>[];
    for (final t in events) {
      final start = tripDay(t.startsAt, t.timeZone);
      var lane = lanes.indexWhere(
        (list) => tripDay(list.last.endsAt, list.last.timeZone).isBefore(start),
      );
      if (lane < 0) {
        lane = lanes.length;
        lanes.add([]);
      }
      lanes[lane].add(t);
    }
    return LayoutBuilder(
      builder: (context, box) {
        final cell = box.maxWidth / 7;
        return SizedBox(
          height: 44 + lanes.length * laneHeight,
          child: Stack(
            children: [
              Row(
                children: [
                  for (var d = 0; d < 7; d++)
                    Expanded(
                      child: Container(
                        height: 44 + lanes.length * laneHeight,
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xff9babb6)),
                          color:
                              DateUtils.isSameDay(
                                first.add(Duration(days: d)),
                                widget.today,
                              )
                              ? const Color(0xffc7e5f1)
                              : Colors.white,
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          '${first.add(Duration(days: d)).day}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
              for (var lane = 0; lane < lanes.length; lane++)
                for (final t in lanes[lane])
                  Positioned(
                    top: 40 + lane * laneHeight,
                    left:
                        tripDay(
                              t.startsAt,
                              t.timeZone,
                            ).difference(first).inDays.clamp(0, 6) *
                            cell +
                        2,
                    width:
                        (tripDay(
                                  t.endsAt,
                                  t.timeZone,
                                ).difference(first).inDays.clamp(0, 6) -
                                tripDay(
                                  t.startsAt,
                                  t.timeZone,
                                ).difference(first).inDays.clamp(0, 6) +
                                1) *
                            cell -
                        4,
                    height: eventHeight,
                    child: _event(t),
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _event(Trip trip) {
    final value = TripOccupancy.read(widget.controller, trip);
    final title = '${tripTime(trip)} · ${trip.title}';
    final count = trip.capacityKnown
        ? '${value.booked} / ${trip.capacity}'
        : '${value.booked} клиентов';
    final status = '$count · ${value.label(trip)}';
    return Tooltip(
      message: '$title\n$status',
      excludeFromSemantics: true,
      child: Material(
        color: value.foreground(trip),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => widget.onOpen(trip),
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
