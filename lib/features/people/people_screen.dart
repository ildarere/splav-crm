import 'worker_schedule.dart';
import 'work_schedule_screen.dart';
import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import 'person_editor.dart';
import 'people_conflicts.dart';
import '../../app/sync_widgets.dart';

class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  String _search = '';
  bool _archived = false;
  int _visibleLimit = 30;
  Future<void> _edit([PersonCard? person, bool worker = false]) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (_) => PersonEditor(
        teams: widget.controller.teams,
        people: widget.controller.peopleView.people,
        person: person,
        worker: worker,
      ),
    );
    if (result == null) return;
    if (result['use_existing'] case final String id) {
      final existing = widget.controller.peopleView.person(id);
      if (existing != null) await _edit(existing);
      return;
    }
    try {
      await widget.controller.savePerson(
        result,
        teamId: result['team_id'] as String,
        previous: person,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Сначала разрешите конфликт или проверьте введённые данные.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _archive(PersonCard person) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          person.archived
              ? 'Восстановить карточку?'
              : 'Перенести карточку в архив?',
        ),
        content: Text(person.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.controller.savePerson(
        {...person.payload, 'archived': !person.archived},
        teamId: person.teamId,
        previous: person,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сначала разрешите предыдущее изменение карточки.'),
          ),
        );
      }
    }
  }

  Future<void> _merge(PersonCard source) async {
    final targets = widget.controller.peopleView.people
        .where(
          (p) =>
              p.id != source.id &&
              p.teamId == source.teamId &&
              !p.archived &&
              p.mergedInto == null,
        )
        .toList();
    String? selected;
    final target = await showDialog<PersonCard>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Объединить карточки'),
          scrollable: true,
          content: SizedBox(
            width: 500,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text(
                  'Перенести участия и контактные ссылки из «${source.name}» в выбранную карточку.',
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Оставить карточку',
                  ),
                  items: targets
                      .map(
                        (p) => DropdownMenuItem(
                          value: p.id,
                          child: Text('${p.name} · ${p.phone}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => selected = v),
                ),
                const Text(
                  'Если обе карточки есть в одном выезде, объединение потребует разбора их участий.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(
                      context,
                      targets.firstWhere((p) => p.id == selected),
                    ),
              child: const Text('Объединить'),
            ),
          ],
        ),
      ),
    );
    if (target != null) {
      try {
        await widget.controller.mergePeople(source, target);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Сначала завершите изменения выбранных карточек.'),
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final query = _search.trim().toLowerCase().replaceAll('ё', 'е');
      final phone = normalizedPhone(query);
      final people = controller.peopleView.people
          .where(
            (p) =>
                p.mergedInto == null &&
                (_archived || !p.archived) &&
                (p.name.toLowerCase().replaceAll('ё', 'е').contains(query) ||
                    (phone.isNotEmpty &&
                        normalizedPhone(p.phone).contains(phone))),
          )
          .toList();
      return SyncRefreshScope(
        controller: controller,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: syncToolbarHeight(context),
            title: SyncPageTitle(title: 'Люди', controller: controller),
            actions: [RefreshAction(controller: controller)],
          ),
          body: PullToRefresh(
            controller: controller,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 16,
                    children: [
                      PeopleConflicts(controller: controller),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.spaceBetween,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) =>
                                    WorkScheduleScreen(controller: controller),
                              ),
                            ),
                            icon: const Icon(Icons.calendar_month_outlined),
                            label: const Text('График работ'),
                          ),
                          FilledButton.icon(
                            onPressed: controller.teams.isEmpty
                                ? null
                                : () => _edit(),
                            icon: const Icon(Icons.person_add_alt_1),
                            label: const Text('Новый человек'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: controller.teams.any((t) => t.canCreate)
                                ? () => _edit(null, true)
                                : null,
                            icon: const Icon(Icons.badge_outlined),
                            label: const Text('Новый работник'),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Показать архив'),
                              Switch(
                                value: _archived,
                                onChanged: (v) => setState(() => _archived = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Поиск по имени или телефону',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (v) => setState(() {
                          _search = v;
                          _visibleLimit = 30;
                        }),
                      ),
                      if (people.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Карточек по выбранным условиям нет.'),
                        ),
                      for (final person in people.take(_visibleLimit))
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              spacing: 8,
                              children: [
                                Text(
                                  person.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                if (person.isWorker)
                                  Text(
                                    'Работник · ${person.workRoles.map((r) => workerRoles[r] ?? r).join(' · ')}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                if (person.phone.isNotEmpty)
                                  SelectableText(person.phone),
                                if (person.birthDate != null)
                                  Text('Дата рождения · ${person.birthDate}'),
                                if (person.notes.isNotEmpty) Text(person.notes),
                                if (person.archived) const Text('В архиве'),
                                if (person.pending)
                                  Text(
                                    person.conflict
                                        ? 'Изменение требует решения'
                                        : 'Сохранено на устройстве · ожидает обмена',
                                  ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (person.isWorker)
                                      FilledButton.tonalIcon(
                                        onPressed: () => Navigator.push(
                                          context,
                                          MaterialPageRoute<void>(
                                            builder: (_) => WorkerSchedule(
                                              controller: controller,
                                              personId: person.id,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(Icons.calendar_month),
                                        label: const Text('График работы'),
                                      ),
                                    OutlinedButton(
                                      onPressed:
                                          person.isWorker &&
                                              !controller.teams.any(
                                                (t) =>
                                                    t.id == person.teamId &&
                                                    t.canCreate,
                                              )
                                          ? null
                                          : () => _edit(person),
                                      child: const Text('Изменить'),
                                    ),
                                    TextButton(
                                      onPressed: () => _archive(person),
                                      child: Text(
                                        person.archived
                                            ? 'Восстановить'
                                            : 'В архив',
                                      ),
                                    ),
                                    if (controller.teams.any(
                                      (t) =>
                                          t.id == person.teamId && t.canCreate,
                                    ))
                                      TextButton(
                                        onPressed: () => _merge(person),
                                        child: const Text('Объединить'),
                                      ),
                                    TextButton(
                                      onPressed: () => showDialog<void>(
                                        context: context,
                                        builder: (_) => _History(
                                          controller: controller,
                                          person: person,
                                        ),
                                      ),
                                      child: const Text('История выездов'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (people.length > _visibleLimit)
                        OutlinedButton(
                          onPressed: () => setState(() => _visibleLimit += 30),
                          child: Text(
                            'Показать ещё · осталось ${people.length - _visibleLimit}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _History extends StatelessWidget {
  const _History({required this.controller, required this.person});
  final Stage1Controller controller;
  final PersonCard person;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(person.name),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: FutureBuilder<List<JsonMap>>(
        future: controller.database.personHistory(person.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const LinearProgressIndicator();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              const Text('История из загруженных на устройство выездов'),
              if (snapshot.data!.isEmpty)
                const Text('Сохранённых участий пока нет.'),
              for (final row in snapshot.data!)
                Text(
                  '${row['title']} · ${participationLabel(row['status'] as String)}\n${row['starts_at']}',
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Закрыть'),
      ),
    ],
  );
}
