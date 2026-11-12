import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import 'trip_format.dart';

Future<Trip?> chooseDestinationTrip(
  BuildContext context,
  Iterable<Trip> options, {
  required String title,
  required String detail,
}) {
  final trips = options.toList()
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  return showDialog<Trip>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(title),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            trips.isEmpty ? 'Нет доступных выездов для переноса.' : detail,
          ),
        ),
        for (final trip in trips)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, trip),
            child: Text('${tripDates(trip)} · ${trip.title}'),
          ),
      ],
    ),
  );
}

String weekdayRange(Trip trip) {
  const names = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
  final first = tripLocalDate(trip.startsAt, trip.timeZone);
  final last = tripLocalDate(trip.endsAt, trip.timeZone);
  final a = first.weekday, b = last.weekday;
  final sameDay =
      first.year == last.year &&
      first.month == last.month &&
      first.day == last.day;
  return sameDay ? names[a - 1] : '${names[a - 1]}–${names[b - 1]}';
}

String tripDates(Trip trip) {
  final start = tripDate(trip.startsAt, trip.timeZone, includeTime: false);
  final end = tripDate(trip.endsAt, trip.timeZone, includeTime: false);
  return '${start == end ? start : '$start — $end'} (${weekdayRange(trip)})';
}

String tripTime(Trip trip) => trip.dateOnly
    ? 'время не указано'
    : tripDate(trip.startsAt, trip.timeZone).split(' ').last;
String tripMoney(int cents) {
  final digits = (cents ~/ 100).toString();
  final parts = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    parts.insert(0, digits.substring((end - 3).clamp(0, end), end));
  }
  return '${parts.join(' ')}${cents % 100 == 0 ? '' : ',${(cents % 100).toString().padLeft(2, '0')}'} ₽';
}

class TripOccupancy {
  const TripOccupancy(
    this.booked,
    this.confirmed,
    this.waiting,
    this.instructors, {
    this.pending = false,
  });
  final int booked, confirmed, waiting, instructors;
  final bool pending;
  static const nearCapacityForeground = Color(0xff795600);
  static const fullForeground = Color(0xffa92132);
  static TripOccupancy read(Stage1Controller c, Trip trip) {
    if (c.selectedTripId == trip.id && c.hasPeople && c.peopleView.ready) {
      final people = c.peopleView.participations
          .where((p) => p.data['legacy_rejection'] != true)
          .toList();
      String status(Participation p) => p.requestedStatus ?? p.status;
      return TripOccupancy(
        people
            .where(
              (p) =>
                  p.role == 'client' &&
                  ['application', 'confirmed'].contains(status(p)),
            )
            .length,
        c.peopleView.confirmedCount,
        people
            .where((p) => p.role == 'client' && status(p) == 'waiting')
            .length,
        c.peopleView.instructorCount,
        pending: people.any((p) => p.pending),
      );
    }
    return TripOccupancy(
      trip.bookedClients,
      trip.confirmedClients,
      trip.waitingClients,
      trip.instructors,
      pending: c.peopleView.commands.any((cmd) => cmd.tripId == trip.id),
    );
  }

  bool exceeded(Trip t) => t.capacityKnown && booked > t.capacity;
  Color background(Trip t) => !t.capacityKnown
      ? const Color(0xffedf6fa)
      : booked >= t.capacity
      ? const Color(0xffffeded)
      : booked >= t.capacity * .8
      ? const Color(0xfffff5d4)
      : const Color(0xffedf6fa);
  Color foreground(Trip t) => !t.capacityKnown
      ? const Color(0xff587184)
      : booked >= t.capacity
      ? fullForeground
      : booked >= t.capacity * .8
      ? nearCapacityForeground
      : const Color(0xff22607b);
  String label(Trip t) => !t.capacityKnown
      ? 'Лимит не указан'
      : exceeded(t)
      ? 'Сверх лимита +${booked - t.capacity}'
      : booked == t.capacity
      ? 'Заполнен'
      : booked >= t.capacity * .8
      ? 'Почти заполнен'
      : 'Есть места';
}

class OccupancyBadge extends StatelessWidget {
  const OccupancyBadge({
    super.key,
    required this.trip,
    required this.value,
    this.compact = false,
  });
  final Trip trip;
  final TripOccupancy value;
  final bool compact;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 8 : 12,
      vertical: compact ? 5 : 10,
    ),
    decoration: BoxDecoration(
      color: value.background(trip),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${trip.capacityKnown
              ? '${value.booked} / ${trip.capacity}'
              : value.booked == 0
              ? 'Состав не указан'
              : '${value.booked} клиентов'}${value.pending ? ' · ожидает обмена' : ''}',
          style: TextStyle(
            color: value.foreground(trip),
            fontWeight: FontWeight.w700,
            fontSize: compact ? 12 : 14,
          ),
        ),
        if (!compact)
          Text(
            value.label(trip),
            style: TextStyle(fontSize: 12, color: value.foreground(trip)),
          ),
      ],
    ),
  );
}

class CapacityNotice extends StatelessWidget {
  const CapacityNotice({super.key, required this.trip, required this.value});
  final Trip trip;
  final TripOccupancy value;
  @override
  Widget build(BuildContext context) => !value.exceeded(trip)
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xffffeded),
            border: Border.all(color: const Color(0xffefbdc4)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xffa92132)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Лимит превышен на ${value.booked - trip.capacity}: записано ${value.booked} из ${trip.capacity} клиентов.'
                  '${value.pending ? ' Учитываются локальные изменения.' : ''} Добавление и подтверждение доступны.',
                  style: const TextStyle(color: Color(0xff842032)),
                ),
              ),
            ],
          ),
        );
}

class TripStateLabel extends StatelessWidget {
  const TripStateLabel({super.key, required this.trip});
  final Trip trip;
  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (trip.syncState) {
      TripSyncState.pending => (
        Icons.schedule_rounded,
        'Ожидает обмена',
        const Color(0xff735000),
      ),
      TripSyncState.conflict => (
        Icons.error_outline,
        'Требует решения',
        const Color(0xffa92132),
      ),
      _ => (
        Icons.circle,
        tripStatusLabel(trip.status),
        const Color(0xff2b596a),
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }
}
