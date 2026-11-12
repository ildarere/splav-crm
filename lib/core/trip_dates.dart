import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'stage1_models.dart';

DateTime tripDay(DateTime instant, String zone) {
  try {
    tz.getLocation('Europe/Saratov');
  } catch (_) {
    tzdata.initializeTimeZones();
  }
  final value = tz.TZDateTime.from(instant, tz.getLocation(zone));
  return DateTime(value.year, value.month, value.day);
}

bool inHomeWindow(Trip trip, DateTime now) {
  final today = tripDay(now, trip.timeZone);
  final from = today.subtract(const Duration(days: 1));
  final until = today.add(const Duration(days: 8));
  return !tripDay(
        trip.startsAt,
        trip.timeZone,
      ).isAfter(until.subtract(const Duration(days: 1))) &&
      !tripDay(
        trip.endsAt.subtract(const Duration(microseconds: 1)),
        trip.timeZone,
      ).isBefore(from);
}

bool overlapsDays(Trip trip, DateTime from, DateTime until) =>
    !tripDay(trip.startsAt, trip.timeZone).isAfter(until) &&
    !tripDay(
      trip.endsAt.subtract(const Duration(microseconds: 1)),
      trip.timeZone,
    ).isBefore(from);
