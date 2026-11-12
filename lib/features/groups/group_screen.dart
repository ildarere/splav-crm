import 'package:flutter/material.dart';

import '../../core/prototype.dart';

class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.controller});

  final PrototypeController controller;

  Future<void> _addParticipant(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _ParticipantDialog(),
    );
    if (name == null || !context.mounted) return;
    try {
      await controller.addParticipant(name);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось сохранить запись на устройстве.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.kayaking_rounded),
            SizedBox(width: 10),
            Text('Сплавы'),
          ],
        ),
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 760 &&
                MediaQuery.textScalerOf(context).scale(16) <= 22;
            final group = controller.group;
            final syncPanel = _SyncPanel(controller: controller);
            final overview = group == null
                ? null
                : _GroupOverview(
                    group: group,
                    confirmedCount: controller.confirmedCount,
                    pendingCount: controller.pendingCount,
                  );
            final participants = group == null
                ? null
                : _ParticipantList(
                    participants: controller.participants,
                    onAdd: () => _addParticipant(context),
                  );

            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: wide ? 28 : 16,
                vertical: wide ? 24 : 12,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 12),
                        child: Text(
                          'Тестовый выезд',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      if (overview == null || participants == null) ...[
                        const _WaitingForGroup(),
                        const SizedBox(height: 16),
                        syncPanel,
                      ] else if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 4,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  overview,
                                  const SizedBox(height: 16),
                                  syncPanel,
                                ],
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(flex: 6, child: participants),
                          ],
                        )
                      else ...[
                        overview,
                        const SizedBox(height: 12),
                        syncPanel,
                        const SizedBox(height: 12),
                        participants,
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WaitingForGroup extends StatelessWidget {
  const _WaitingForGroup();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Группа ещё не загружена',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Подключитесь к серверу и нажмите «Синхронизировать». '
            'После первой загрузки список доступен без связи.',
          ),
        ],
      ),
    );
  }
}

class _GroupOverview extends StatelessWidget {
  const _GroupOverview({
    required this.group,
    required this.confirmedCount,
    required this.pendingCount,
  });

  final PrototypeGroup group;
  final int confirmedCount;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _Panel(
      color: colors.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.kayaking_rounded,
            color: colors.onPrimaryContainer,
            size: 36,
          ),
          const SizedBox(height: 12),
          Text(
            group.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(group.route, style: TextStyle(color: colors.onPrimaryContainer)),
          const SizedBox(height: 4),
          Text(
            _formatDateTime(group.startsAt),
            style: TextStyle(color: colors.onPrimaryContainer),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Badge(
                icon: Icons.event_seat_outlined,
                label: 'Подтверждено $confirmedCount из ${group.capacity}',
              ),
              if (pendingCount > 0)
                _Badge(
                  icon: Icons.schedule_rounded,
                  label: 'Ожидают $pendingCount',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SyncPanel extends StatelessWidget {
  const _SyncPanel({required this.controller});

  final PrototypeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final syncing = controller.isSyncing;
    final offline = controller.isOffline;
    final lastSyncedAt = controller.lastSyncedAt;
    final error = controller.error;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Синхронизация', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              offline
                  ? 'Офлайн-режим. Новые записи сохраняются на устройстве.'
                  : syncing
                  ? 'Обмениваемся данными с сервером…'
                  : error ??
                        (controller.group == null
                            ? 'Ожидается первая загрузка.'
                            : 'Группа доступна офлайн.'),
              style: TextStyle(
                color: error != null && !offline && !syncing
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (lastSyncedAt != null) ...[
            const SizedBox(height: 6),
            Text(
              'Последний обмен · ${_formatDateTime(lastSyncedAt)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            value: offline,
            onChanged: syncing ? null : controller.setOffline,
            contentPadding: EdgeInsets.zero,
            title: const Text('Без сети'),
            subtitle: const Text('Приостановить обмен для проверки офлайна'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: syncing || offline ? null : controller.sync,
            icon: const Icon(Icons.sync_rounded),
            label: const Text('Синхронизировать'),
          ),
        ],
      ),
    );
  }
}

class _ParticipantList extends StatelessWidget {
  const _ParticipantList({required this.participants, required this.onAdd});

  final List<PrototypeParticipant> participants;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text('Участники', style: theme.textTheme.titleLarge),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Добавить участника'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (participants.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'В списке пока никого нет. Добавьте первого участника.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          else
            for (final participant in participants) ...[
              const Divider(height: 1),
              _ParticipantRow(participant: participant),
            ],
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({required this.participant});

  final PrototypeParticipant participant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, status, color) = switch (participant.status) {
      ParticipantStatus.confirmed => (
        Icons.check_circle_outline_rounded,
        'Подтверждено',
        theme.colorScheme.primary,
      ),
      ParticipantStatus.pending => (
        Icons.schedule_rounded,
        'Ожидает подтверждения',
        theme.colorScheme.onSurfaceVariant,
      ),
      ParticipantStatus.rejected => (
        Icons.error_outline_rounded,
        'Требует решения',
        theme.colorScheme.error,
      ),
    };
    final reason = switch (participant.reason) {
      'capacity_reached' => 'Свободных мест больше нет.',
      'already_registered' => 'Этот участник уже записан.',
      _ => 'Сервер отклонил запись.',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(participant.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(status, style: TextStyle(color: color)),
              ),
            ],
          ),
          if (participant.status == ParticipantStatus.rejected) ...[
            const SizedBox(height: 4),
            Text(reason, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _ParticipantDialog extends StatefulWidget {
  const _ParticipantDialog();

  @override
  State<_ParticipantDialog> createState() => _ParticipantDialogState();
}

class _ParticipantDialogState extends State<_ParticipantDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, _name.text.trim());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Новая запись'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          maxLength: 100,
          decoration: const InputDecoration(
            labelText: 'Имя и фамилия',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            final name = (value ?? '').trim();
            if (name.isEmpty) return 'Введите имя';
            if (name.runes.length > 100) return 'Сократите имя до 100 символов';
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(18), child: child),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Flexible(child: Text(label, style: theme.textTheme.labelMedium)),
          ],
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final date = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${twoDigits(date.day)}.${twoDigits(date.month)}.${date.year} '
      '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
}
