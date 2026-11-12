import 'package:flutter/material.dart';
import '../../core/prototype.dart';

class PeopleConflicts extends StatelessWidget {
  const PeopleConflicts({super.key, required this.controller, this.tripId});
  final Stage1Controller controller;
  final String? tripId;
  @override
  Widget build(BuildContext context) {
    final commands = controller.peopleView.commands.where(
      (c) =>
          c.error != null &&
          c.tripId == tripId &&
          !financeKinds.contains(c.kind) &&
          !operationsKinds.contains(c.kind),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final command in commands)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  Text(
                    command.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(peopleErrorLabel(command.error)),
                  if (command.kind == 'save_person') ...[
                    Text(
                      'Ваш вариант · ${command.payload['name']} · ${command.payload['phone'] ?? ''}\n${command.payload['notes'] ?? ''}',
                    ),
                    FutureBuilder<JsonMap?>(
                      future: controller.database.serverPerson(
                        command.payload['id'] as String,
                      ),
                      builder: (context, snapshot) {
                        final data = snapshot.data;
                        return Text(
                          data == null
                              ? 'Карточка ещё не создана на сервере.'
                              : 'На сервере · ${data['name']} · ${data['phone']}\n${data['notes']}',
                        );
                      },
                    ),
                  ],
                  if (command.kind == 'set_status') ...[
                    Text(
                      'Выбрано участников · ${(command.payload['ids'] as List).length}',
                    ),
                    Text(
                      'Подтверждено на сервере · ${controller.peopleView.confirmedCount}. Лимит выезда · ${controller.selectedTrip?.capacity ?? 0}.',
                    ),
                  ],
                  if (command.kind == 'save_booking')
                    Text(
                      'Контакт · ${command.payload['contact_name']}\nНовых участников · ${(command.payload['members'] as List).length}',
                    ),
                  if (command.kind == 'edit_participation')
                    Text(
                      'Ваш вариант · ${command.payload['role'] == 'instructor' ? 'Инструктор' : 'Клиент'}\n${_parameters(command.payload['parameters'])}',
                    ),
                  if (command.tripId != null)
                    FutureBuilder<JsonMap?>(
                      future: controller.database.serverRoster(command.tripId!),
                      builder: (context, snapshot) {
                        final roster = snapshot.data;
                        final list =
                            roster?[command.kind == 'save_booking'
                                    ? 'bookings'
                                    : 'participations']
                                as List? ??
                            [];
                        final current = list
                            .where((p) => p['id'] == command.payload['id'])
                            .firstOrNull;
                        if (command.kind == 'save_booking' && current != null) {
                          return Text(
                            'Контакт на сервере · ${current['contact_name']} · ${current['phone']}\n${current['notes']}',
                          );
                        }
                        if (command.kind == 'edit_participation' &&
                            current != null) {
                          return Text(
                            'На сервере · ${current['role'] == 'instructor' ? 'Инструктор' : 'Клиент'}\n${_parameters(current['parameters'])}',
                          );
                        }
                        if (command.kind == 'set_status') {
                          return Text(
                            list
                                .where(
                                  (p) => (command.payload['ids'] as List)
                                      .contains(p['id']),
                                )
                                .map(
                                  (p) =>
                                      '${controller.peopleView.person(p['person_id'] as String)?.name ?? 'Участник'} · ${participationLabel(p['status'] as String)} → ${participationLabel(command.payload['status'] as String)}',
                                )
                                .join('\n'),
                          );
                        }
                        return const SizedBox();
                      },
                    ),
                  if (controller.peopleView.commands.any(
                    (c) => c.dependencies.contains(command.id),
                  ))
                    const Text(
                      'Повтор или отмена этого изменения отменит зависимые локальные действия. Их потребуется создать заново.',
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () async {
                          try {
                            await controller.retryPeopleChange(command);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Не удалось повторить изменение.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        child: const Text('Повторить с текущей версией'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final yes = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Отменить это изменение?'),
                              content: const Text(
                                'Связанные с ним неотправленные действия тоже будут отменены. Данные на сервере сохранятся.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Назад'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Отменить изменение'),
                                ),
                              ],
                            ),
                          );
                          if (yes == true) {
                            await controller.discardPeopleChange(command.id);
                          }
                        },
                        child: const Text('Отменить изменение'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _parameters(dynamic value) => (value as Map).entries
    .map(
      (entry) =>
          '${switch (entry.key) {
            'height_cm' => 'Рост, см',
            'weight_kg' => 'Вес, кг',
            'age_years' => 'Возраст',
            'clothing_size' => 'Размер одежды',
            'food_notes' => 'Питание',
            'notes' => 'Примечание',
            _ => entry.key,
          }} · ${entry.value}',
    )
    .join('\n');
