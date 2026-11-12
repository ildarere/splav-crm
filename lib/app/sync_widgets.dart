import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/stage1_controller.dart';
import '../core/stage1_models.dart';

double syncToolbarHeight(BuildContext context) =>
    (MediaQuery.textScalerOf(context).scale(36) + 12).clamp(56, 120);

/// The sync state belongs to the page header, alongside its refresh action.
class SyncPageTitle extends StatelessWidget {
  const SyncPageTitle({
    super.key,
    required this.title,
    required this.controller,
  });
  final String title;
  final Stage1Controller controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      final conflicts =
          c.peopleView.commands.where((v) => v.error != null).length +
          c.trips.where((t) => t.syncState == TripSyncState.conflict).length;
      final hasError = conflicts > 0 || c.error != null;
      final pending = c.pendingCommandCount;
      final accepted = c.peopleView.commands.any((v) => v.ackRevision != null);
      final status = c.isOffline
          ? 'Без сети · данные на устройстве'
          : c.isSyncing
          ? 'Синхронизация…'
          : hasError
          ? 'Есть изменения, требующие внимания'
          : accepted
          ? 'Сервер принял · получаем результат'
          : pending > 0
          ? 'Сохранено · ожидает синхронизации'
          : 'Данные актуальны';
      final color = hasError
          ? const Color(0xffb13434)
          : c.isOffline || pending > 0
          ? const Color(0xff946300)
          : const Color(0xff087f83);
      final details = [
        status,
        'Обмен выполняется автоматически при наличии связи.',
        if (pending > 0) 'В очереди: $pending',
        if (conflicts > 0) 'Требуют решения: $conflicts',
        if (c.error != null) c.error!,
        if (accepted)
          'Сервер принял изменения; загружаем подтверждённые данные.',
      ].join('\n');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          Tooltip(
            message: details,
            triggerMode: TooltipTriggerMode.tap,
            child: Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Icon(
                    c.isOffline
                        ? Icons.cloud_off_outlined
                        : hasError
                        ? Icons.error_outline
                        : Icons.cloud_done_outlined,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      '$status${pending > 0 ? ' · очередь $pending' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: color, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class SyncRefreshScope extends StatelessWidget {
  const SyncRefreshScope({
    super.key,
    required this.controller,
    required this.child,
  });
  final Stage1Controller controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.f5): () {
        controller.sync();
      },
    },
    child: Focus(autofocus: true, child: child),
  );
}

class RefreshAction extends StatelessWidget {
  const RefreshAction({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => IconButton(
      tooltip: 'Обновить · F5',
      onPressed: controller.isSyncing ? null : controller.sync,
      icon: controller.isSyncing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded),
    ),
  );
}

class PullToRefresh extends StatelessWidget {
  const PullToRefresh({
    super.key,
    required this.controller,
    required this.child,
  });
  final Stage1Controller controller;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      RefreshIndicator(onRefresh: controller.sync, child: child);
}
