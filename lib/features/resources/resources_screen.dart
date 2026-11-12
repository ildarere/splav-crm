import '../people/person_editor.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/prototype.dart';
import '../../app/sync_widgets.dart';
import '../operations/operations_widgets.dart';

Future<void> editResource(
  BuildContext context,
  Stage1Controller c,
  String kind, [
  JsonMap? resource,
]) async {
  if (kind == 'employee') {
    final person = c.peopleView.person(
      resource?['person_id'] as String? ?? resource?['id'] as String? ?? '',
    );
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (_) => PersonEditor(
        teams: c.teams,
        people: c.peopleView.people,
        teamId: c.selectedTrip?.teamId,
        person: person,
        worker: true,
      ),
    );
    if (result == null || result['use_existing'] != null) return;
    await c.savePerson(
      result,
      teamId: result['team_id'] as String,
      previous: person,
    );
    return;
  }
  final result = await operationDialog<JsonMap>(
    context,
    c,
    ResourceEditor(controller: c, kind: kind, resource: resource),
  );
  if (result != null && context.mounted) {
    await performOperation(context, c, 'ops_resources', {
      'items': [result],
    });
  }
}

Future<void> openResources(
  BuildContext context,
  Stage1Controller c,
  String kind,
) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => ResourcesScreen(controller: c, kind: kind),
  ),
);

class ResourcesScreen extends StatelessWidget {
  const ResourcesScreen({
    super.key,
    required this.controller,
    required this.kind,
  });
  final Stage1Controller controller;
  final String kind;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, o = c.operationsView;
      final canEdit = c.teams.any(
        (t) => t.id == c.selectedTrip?.teamId && t.canCreate,
      );
      final rows = o.resources
          .where(
            (r) =>
                r['kind'] == kind &&
                (kind != 'employee' ||
                    c.peopleView
                            .person(r['person_id'] as String? ?? '')
                            ?.archived !=
                        true),
          )
          .toList();
      return SyncRefreshScope(
        controller: c,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: syncToolbarHeight(context),
            title: SyncPageTitle(
              title: kind == 'boat'
                  ? 'Парк байдарок'
                  : kind == 'vehicle'
                  ? 'Транспорт'
                  : 'Справочник работников',
              controller: c,
            ),
            actions: [RefreshAction(controller: c)],
          ),
          body: OperationsScroll(
            controller: c,
            children: [
              if (o.setup == null && canEdit)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        const Text(
                          'Исходные данные: 2 большие лодки, наш автобус на 30 мест, второй автобус, такси, Лиза, Анна Орлова и Варя.',
                        ),
                        const Text(
                          'Количество «Каяк РФ» и «Майгун» нужно уточнить. Эти лодки добавляются отдельно.',
                        ),
                        FilledButton(
                          onPressed: () => c.initializeOperations(),
                          child: const Text('Применить исходные данные'),
                        ),
                      ],
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Всего: ${rows.length} · доступно: ${rows.where((r) => r['available'] == true).length}',
                  ),
                  if (canEdit)
                    FilledButton.icon(
                      onPressed: () => editResource(context, c, kind),
                      icon: const Icon(Icons.add),
                      label: Text(
                        kind == 'boat'
                            ? 'Добавить лодку'
                            : kind == 'vehicle'
                            ? 'Добавить транспорт'
                            : 'Добавить работника',
                      ),
                    ),
                  if (canEdit && kind == 'boat')
                    OutlinedButton(
                      onPressed: () async {
                        final items = await operationDialog<List<JsonMap>>(
                          context,
                          c,
                          BoatBatchEditor(resources: rows),
                        );
                        if (items != null && context.mounted) {
                          await performOperation(context, c, 'ops_resources', {
                            'items': items,
                          });
                        }
                      },
                      child: const Text('Добавить несколько лодок'),
                    ),
                ],
              ),
              if (kind == 'boat')
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Ориентир: «Каяк РФ» — около 20–25; «Майгун» — больше 20. В рассадке участвуют только внесённые ниже единицы. Номера — внутренние учётные обозначения.',
                  ),
                ),
              if (kind == 'employee') ...[
                const SizedBox(height: 12),
                const Text(
                  'Кадровый резерв — число работников в справочнике, а не норма на один выезд.',
                ),
                for (final target in workerTargets.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${workerRoles[target.key]}: ${rows.where((r) => r['available'] == true && (r['roles'] as List? ?? []).contains(target.key)).length}'
                      ' · ориентир ${target.value.$1 == target.value.$2 ? '${target.value.$1}' : '${target.value.$1}–${target.value.$2}'}',
                    ),
                  ),
                const SizedBox(height: 12),
              ],
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Справочник пока пуст.'),
                ),
              for (final r in rows)
                Card(
                  child: ListTile(
                    leading: Icon(
                      r['available'] == true
                          ? Icons.check_circle_outline
                          : Icons.block,
                      color: r['available'] == true
                          ? const Color(0xff087c53)
                          : const Color(0xffa53c30),
                    ),
                    title: Text('${r['name']} · ${r['code']}'),
                    subtitle: Text(
                      [
                        if (kind == 'boat')
                          boatModelLabel(r['model'] as String),
                        if (kind == 'vehicle')
                          '${r['capacity']} мест${r['model'] == 'secondary_bus' ? ' · в рейсе 16, 17, 19 или 20' : ''}',
                        if (kind == 'employee')
                          (r['roles'] as List? ?? [])
                              .map((v) => workerRoles[v] ?? v)
                              .join(', '),
                        r['available'] == true ? 'Доступен' : 'Недоступен',
                        if ((r['notes'] as String? ?? '').isNotEmpty)
                          r['notes'] as String,
                        if (r['pending'] == true)
                          r['conflict'] == true
                              ? 'Требует решения'
                              : 'На устройстве',
                      ].join(' · '),
                    ),
                    trailing: canEdit
                        ? IconButton(
                            tooltip: 'Изменить',
                            onPressed: () => editResource(context, c, kind, r),
                            icon: const Icon(Icons.edit_outlined),
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class ResourceEditor extends StatefulWidget {
  const ResourceEditor({
    super.key,
    required this.controller,
    required this.kind,
    this.resource,
    this.initialModel,
  });
  final Stage1Controller controller;
  final String kind;
  final String? initialModel;
  final JsonMap? resource;
  @override
  State<ResourceEditor> createState() => _ResourceEditorState();
}

class _ResourceEditorState extends State<ResourceEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.resource?['name'] as String? ?? '',
  );
  late final _code = TextEditingController(
    text:
        widget.resource?['code'] as String? ??
        const Uuid().v4().substring(0, 8),
  );
  late final _notes = TextEditingController(
    text: widget.resource?['notes'] as String? ?? '',
  );
  late final _capacity = TextEditingController(
    text:
        '${widget.resource?['capacity'] ?? (widget.kind == 'boat'
                ? 4
                : widget.kind == 'vehicle'
                ? 30
                : 0)}',
  );
  late String _model =
      widget.resource?['model'] as String? ??
      widget.initialModel ??
      (widget.kind == 'boat'
          ? 'big'
          : widget.kind == 'vehicle'
          ? 'own_bus'
          : 'employee');
  late bool _available = widget.resource?['available'] as bool? ?? true;
  late final _roles = (widget.resource?['roles'] as List? ?? [])
      .cast<String>()
      .toSet();
  late String? _person = widget.resource?['person_id'] as String?;
  String? _error;
  @override
  void dispose() {
    for (final c in [_name, _code, _notes, _capacity]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (widget.kind == 'employee' && _roles.isEmpty) {
      setState(() => _error = 'Выберите специализацию работника.');
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'id': widget.resource?['id'] ?? const Uuid().v4(),
      'version': widget.resource?['version'] ?? 0,
      'kind': widget.kind,
      'name': _name.text.trim(),
      'code': _code.text.trim(),
      'model': _model,
      'capacity': int.parse(_capacity.text),
      'available': _available,
      'roles': _roles.toList(),
      'person_id': _person,
      'notes': _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final people = widget.controller.peopleView.people
        .where(
          (p) =>
              p.teamId == widget.controller.selectedTrip?.teamId && !p.archived,
        )
        .toList();
    return AlertDialog(
      title: Text(widget.resource == null ? 'Новая запись' : 'Изменить запись'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Название / имя'),
                maxLength: 150,
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'Укажите название или имя'
                    : null,
              ),
              TextFormField(
                controller: _code,
                decoration: const InputDecoration(
                  labelText: 'Учётный номер / обозначение',
                ),
                maxLength: 60,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Укажите обозначение' : null,
              ),
              if (widget.kind != 'employee') ...[
                DropdownButtonFormField<String>(
                  initialValue: _model,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Тип'),
                  items: [
                    for (final e
                        in (widget.kind == 'boat'
                                ? const {
                                    'big': 'Большая',
                                    'rf': 'Каяк РФ',
                                    'maigun': 'Майгун',
                                    'custom': 'Другая лодка',
                                  }
                                : const {
                                    'own_bus': 'Наш автобус',
                                    'secondary_bus': 'Второй автобус',
                                    'taxi': 'Такси',
                                    'custom': 'Другой транспорт',
                                  })
                            .entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() {
                    _model = v!;
                    _capacity.text = switch (v) {
                      'big' => '4',
                      'rf' => '3',
                      'maigun' => '2',
                      'own_bus' => '30',
                      'secondary_bus' => '20',
                      'taxi' => '4',
                      _ => widget.kind == 'boat' ? '2' : '4',
                    };
                  }),
                ),
                TextFormField(
                  controller: _capacity,
                  keyboardType: TextInputType.number,
                  readOnly: _model != 'custom',
                  decoration: const InputDecoration(
                    labelText: 'Максимальная вместимость',
                  ),
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n == null ||
                            n < (widget.kind == 'boat' ? 2 : 1) ||
                            n > (widget.kind == 'boat' ? 4 : 100)
                        ? 'Проверьте число мест'
                        : null;
                  },
                ),
              ] else ...[
                const Text('Специализации'),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final role in workerRoles.entries)
                      FilterChip(
                        label: Text(role.value),
                        selected: _roles.contains(role.key),
                        onSelected: (v) => setState(() {
                          v ? _roles.add(role.key) : _roles.remove(role.key);
                          _error = null;
                        }),
                      ),
                  ],
                ),
                DropdownButtonFormField<String>(
                  initialValue: people.any((p) => p.id == _person)
                      ? _person
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Карточка человека (необязательно)',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Без привязки'),
                    ),
                    for (final p in people)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => _person = v,
                ),
                const Text(
                  'Привязка помогает не учитывать одного человека дважды — как работника и как участника. Инструктора для выхода на воду добавьте в состав выезда.',
                ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Доступен для назначения'),
                value: _available,
                onChanged: (v) => setState(() => _available = v!),
              ),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Примечание'),
                maxLength: 2000,
                maxLines: 3,
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}

class BoatBatchEditor extends StatefulWidget {
  const BoatBatchEditor({super.key, required this.resources});
  final List<JsonMap> resources;
  @override
  State<BoatBatchEditor> createState() => _BoatBatchEditorState();
}

class _BoatBatchEditorState extends State<BoatBatchEditor> {
  final _form = GlobalKey<FormState>(),
      _count = TextEditingController(text: '20');
  String _model = 'rf';
  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Добавить лодки в парк'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            const Text(
              'Укажите фактическое количество добавляемых лодок. Ориентиры 20–25 и больше 20 не считаются подтверждённым наличием.',
            ),
            DropdownButtonFormField<String>(
              initialValue: _model,
              decoration: const InputDecoration(labelText: 'Тип лодки'),
              items: const [
                DropdownMenuItem(value: 'rf', child: Text('Каяк РФ')),
                DropdownMenuItem(value: 'maigun', child: Text('Майгун')),
              ],
              onChanged: (v) => setState(() {
                _model = v!;
                _count.text = v == 'rf' ? '20' : '21';
              }),
            ),
            TextFormField(
              controller: _count,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Добавить единиц'),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return n == null || n < 1 || n > 100
                    ? 'От 1 до 100 лодок за один раз'
                    : null;
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final prefix = _model == 'rf' ? 'РФ' : 'М';
          var serial = 0;
          for (final r in widget.resources) {
            final code = r['code'] as String? ?? '';
            if (code.startsWith('$prefix-')) {
              final n = int.tryParse(code.substring(prefix.length + 1));
              if (n != null && n > serial) serial = n;
            }
          }
          Navigator.pop(context, [
            for (var i = 1; i <= int.parse(_count.text); i++)
              <String, dynamic>{
                'id': const Uuid().v4(),
                'kind': 'boat',
                'name':
                    '${_model == 'rf' ? 'Каяк РФ' : 'Майгун'} ${serial + i}',
                'code': '$prefix-${(serial + i).toString().padLeft(2, '0')}',
                'model': _model,
                'capacity': _model == 'rf' ? 3 : 2,
                'available': true,
                'roles': <String>[],
                'notes': '',
                'version': 0,
              },
          ]);
        },
        child: const Text('Добавить в парк'),
      ),
    ],
  );
}
