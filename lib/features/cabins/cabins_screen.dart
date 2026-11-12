import 'package:flutter/material.dart';

import '../../core/company_color.dart';
import '../../core/prototype.dart';
import '../operations/operations_widgets.dart';

class CabinsScreen extends StatefulWidget {
  const CabinsScreen({super.key, required this.controller});
  final Stage1Controller controller;

  @override
  State<CabinsScreen> createState() => _CabinsScreenState();
}

class _CabinsScreenState extends State<CabinsScreen> {
  bool _saving = false;

  Future<void> _save(
    Set<int> extraBeds,
    Map<String, int> assignments,
    int version,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await performOperation(context, widget.controller, 'ops_cabins', {
        'extra_beds': extraBeds.toList()..sort(),
        'assignments': assignments,
      }, version: version);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static final _cabins = [
    for (var number = 1; number <= 21; number++)
      if (number != 13) number,
  ];

  static int _capacity(int cabin, Set<int> extraBeds) =>
      (cabin <= 5 ? 4 : 2) + (extraBeds.contains(cabin) ? 1 : 0);

  void _distribute(
    List<Participation> people,
    Map<String, int> assignments,
    Set<int> extraBeds,
  ) {
    final companies = <String, List<Participation>>{};
    for (final person in people) {
      if (!assignments.containsKey(person.id)) {
        companies.putIfAbsent(person.bookingId, () => []).add(person);
      }
    }
    final groups = companies.values.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final byId = {for (final person in people) person.id: person};
    for (final company in groups) {
      final candidates = <(int, int, bool)>[];
      for (final cabin in _cabins) {
        final residents = assignments.entries
            .where((e) => e.value == cabin)
            .toList();
        final free = _capacity(cabin, extraBeds) - residents.length;
        if (free > 0 &&
            residents.every(
              (e) => byId[e.key]!.bookingId == company.first.bookingId,
            )) {
          candidates.add((cabin, free, residents.isNotEmpty));
        }
      }
      while (company.isNotEmpty && candidates.isNotEmpty) {
        candidates.sort((a, b) {
          final aFits = a.$2 >= company.length;
          final bFits = b.$2 >= company.length;
          if (aFits != bFits) return aFits ? -1 : 1;
          if (a.$3 != b.$3) return a.$3 ? -1 : 1;
          return aFits ? a.$2.compareTo(b.$2) : b.$2.compareTo(a.$2);
        });
        final (cabin, free, _) = candidates.removeAt(0);
        for (var seat = 0; seat < free && company.isNotEmpty; seat++) {
          assignments[company.removeAt(0).id] = cabin;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final tripId = c.selectedTripId;
    final settings = c.operationsView.settings;
    final plan = settings['cabins'] as Map? ?? {};
    final version = settings['cabins_version'] as int? ?? 0;
    final oldPlan = plan.containsKey('numbers');
    final review = plan['review'] as Map? ?? {};
    final people = c.peopleView.participations
        .where(
          (p) =>
              p.data['legacy'] != true &&
              p.role == 'client' &&
              (p.requestedStatus ?? p.status) == 'confirmed',
        )
        .toList();
    final assignments = <String, int>{
      for (final p in people)
        if ((plan['assignments'] as Map?)?[p.id] case final int cabin
            when _cabins.contains(cabin))
          p.id: cabin,
    };
    final extraBeds = (plan['extra_beds'] as List? ?? const [])
        .cast<int>()
        .toSet();
    final editable =
        !_saving &&
        !oldPlan &&
        c.operationsView.ready &&
        !c.operationsView.commands.any(
          (command) =>
              command.tripId == tripId &&
              command.kind == 'ops_cabins' &&
              command.error != null,
        ) &&
        !['completed', 'cancelled'].contains(c.selectedTrip?.status);
    List<Participation> residents(int? cabin) =>
        people.where((p) => assignments[p.id] == cabin).toList();
    bool canMove(Participation p, int? cabin) {
      if (!editable || assignments[p.id] == cabin) return false;
      if (cabin == null) return true;
      final occupants = residents(cabin);
      return occupants.length < _capacity(cabin, extraBeds) &&
          occupants.every((other) => other.bookingId == p.bookingId);
    }

    void move(Participation person, int? cabin) {
      if (c.selectedTripId != tripId || !canMove(person, cabin)) return;
      final updated = {...assignments};
      if (cabin == null) {
        updated.remove(person.id);
      } else {
        updated[person.id] = cabin;
      }
      _save(extraBeds, updated, version);
    }

    Widget tag(Participation p) {
      final name = c.peopleView.person(p.personId)?.name ?? 'Участник';
      final reason = switch (review[p.id]) {
        'removed_cabin' => 'Домика № 13 больше нет',
        'invalid_number' => 'Прежнего номера нет в списке домиков',
        'capacity_changed' => 'В домике стало меньше мест',
        _ => null,
      };
      final label = ActionChip(
        visualDensity: VisualDensity.compact,
        backgroundColor: companyColor(p.bookingId),
        label: Text(
          assignments[p.id] == null && reason != null
              ? '$name · $reason'
              : name,
          style: const TextStyle(color: Colors.black87),
        ),
        onPressed: editable
            ? () async {
                final destination = await showDialog<int>(
                  context: context,
                  builder: (dialog) => SimpleDialog(
                    title: Text(name),
                    children: [
                      if (canMove(p, null))
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(dialog, 0),
                          child: const Text('Без домика'),
                        ),
                      for (final cabin in _cabins.where(
                        (cabin) => canMove(p, cabin),
                      ))
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(dialog, cabin),
                          child: Text('Домик № $cabin'),
                        ),
                      if (!canMove(p, null) &&
                          !_cabins.any((cabin) => canMove(p, cabin)))
                        const SimpleDialogOption(
                          child: Text('Нет подходящих домиков'),
                        ),
                    ],
                  ),
                );
                if (destination != null && mounted) {
                  move(p, destination == 0 ? null : destination);
                }
              }
            : null,
      );
      if (!editable) return label;
      final feedback = Material(type: MaterialType.transparency, child: label);
      return switch (Theme.of(context).platform) {
        TargetPlatform.windows ||
        TargetPlatform.linux ||
        TargetPlatform.macOS => Draggable<Participation>(
          data: p,
          feedback: feedback,
          child: label,
        ),
        _ => LongPressDraggable<Participation>(
          data: p,
          feedback: feedback,
          child: label,
        ),
      };
    }

    Widget target(int? cabin) => DragTarget<Participation>(
      hitTestBehavior: HitTestBehavior.opaque,
      onWillAcceptWithDetails: (details) => canMove(details.data, cabin),
      onAcceptWithDetails: (details) => move(details.data, cabin),
      builder: (context, candidates, _) {
        final occupants = residents(cabin);
        return Card(
          color: candidates.isEmpty
              ? null
              : Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        cabin == null
                            ? 'Без домика · ${occupants.length}'
                            : '№ $cabin · ${occupants.length}/${_capacity(cabin, extraBeds)}',
                      ),
                    ),
                    if (editable && cabin != null)
                      IconButton(
                        tooltip: extraBeds.contains(cabin)
                            ? 'Убрать дополнительное место'
                            : 'Добавить дополнительное место',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          extraBeds.contains(cabin)
                              ? Icons.remove_circle_outline
                              : Icons.add_circle_outline,
                          size: 17,
                        ),
                        onPressed:
                            extraBeds.contains(cabin) &&
                                occupants.length == _capacity(cabin, extraBeds)
                            ? null
                            : () {
                                final updated = {...extraBeds};
                                if (!updated.remove(cabin)) updated.add(cabin);
                                _save(updated, assignments, version);
                              },
                      ),
                  ],
                ),
                if (occupants.isNotEmpty)
                  Wrap(spacing: 4, children: occupants.map(tag).toList()),
              ],
            ),
          ),
        );
      },
    );

    return OperationsScroll(
      controller: c,
      children: [
        if (oldPlan)
          const Text(
            'Обновите данные выезда, чтобы загрузить новую нумерацию домиков.',
          ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Занято ${assignments.length} из ${50 + extraBeds.length}'),
            FilledButton.tonal(
              onPressed: editable && assignments.length < people.length
                  ? () {
                      final updated = {...assignments};
                      _distribute(people, updated, extraBeds);
                      if (updated.length != assignments.length) {
                        _save(extraBeds, updated, version);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Нет свободных мест для этих компаний.',
                            ),
                          ),
                        );
                      }
                    }
                  : null,
              child: const Text('Распределить автоматически'),
            ),
            TextButton(
              onPressed: () => operationsHistory(context, c),
              child: const Text('История'),
            ),
          ],
        ),
        if (editable)
          const Text(
            'Перетащите имя или нажмите на него, чтобы выбрать домик.',
          ),
        target(null),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / 170).floor().clamp(1, 5);
            final width = constraints.maxWidth / columns;
            return Wrap(
              children: [
                for (final cabin in _cabins)
                  SizedBox(width: width, child: target(cabin)),
              ],
            );
          },
        ),
      ],
    );
  }
}
