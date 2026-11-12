import 'package:flutter/material.dart';
import '../../core/stage1_controller.dart';
import '../../core/stage1_models.dart';
import '../../core/trip_dates.dart';
import '../../app/sync_widgets.dart';
import 'trip_detail.dart';
import 'trip_editor.dart';
import 'trip_format.dart';
import 'trip_presentation.dart';
import 'trip_calendar.dart';
import '../people/people_screen.dart';
export 'trip_presentation.dart' show TripStateLabel;

class TripsScreen extends StatefulWidget {
  const TripsScreen({
    super.key,
    required this.controller,
    required this.email,
    required this.onLogout,
    this.allTrips = false,
    this.initialCalendar = false,
    this.clock,
  });
  final Stage1Controller controller;
  final String email;
  final Future<void> Function() onLogout;
  final bool allTrips, initialCalendar;
  final DateTime Function()? clock;
  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late bool _calendar = widget.initialCalendar;
  String _search = '', _status = 'all';
  late DateTimeRange? _dates = DateTimeRange(
    start: tripDay((widget.clock ?? DateTime.now)(), 'Europe/Saratov'),
    end: tripDay(
      (widget.clock ?? DateTime.now)(),
      'Europe/Saratov',
    ).add(const Duration(days: 7)),
  );
  int _page = 0;
  static const _pageSize = 30;
  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Изменения сохранены на устройстве. Проверьте данные и повторите действие.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _create() async {
    final c = widget.controller;
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => TripEditor(teams: c.teams, routes: c.routes),
    );
    if (result is List<TripDraft>) {
      await _perform(() => c.createTrips(result));
    } else if (result is TripDraft) {
      await _perform(() async {
        await c.saveTrip(result);
      });
    }
  }

  Future<void> _logout() async {
    final c = widget.controller, count = c.pendingCommandCount;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: Text(
          count == 0
              ? 'Локальные копии будут удалены. При следующем входе они загрузятся снова.'
              : 'На устройстве есть неотправленные изменения — $count. Перед выходом их можно отправить или явно удалить.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          if (count > 0)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'sync'),
              child: const Text('Отправить и выйти'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'exit'),
            child: Text(count > 0 ? 'Удалить правки и выйти' : 'Выйти'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'sync') {
      await c.sync();
      if (c.pendingCommandCount > 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Часть изменений ещё не отправлена или требует решения. Выход отменён.',
              ),
            ),
          );
        }
        return;
      }
    }
    await _perform(widget.onLogout);
  }

  Future<void> _open(Trip trip) async {
    await widget.controller.chooseTrip(trip.id);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TripDetail(controller: widget.controller),
      ),
    );
  }

  Future<void> _dateFilter() async {
    final value = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _dates,
      currentDate: tripDay((widget.clock ?? DateTime.now)(), 'Europe/Saratov'),
      helpText: 'Выезды, пересекающие выбранные даты',
      saveText: 'Применить',
    );
    if (value != null && mounted) {
      setState(() {
        _dates = value;
        _page = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return SyncRefreshScope(
      controller: c,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final now = (widget.clock ?? DateTime.now)();
          final today = tripDay(now, 'Europe/Saratov');
          final query = _search.trim().toLowerCase().replaceAll('ё', 'е');
          final trips = c.trips.where((t) {
            if (!'${t.title} ${t.route} ${t.responsibleNames}'
                .toLowerCase()
                .replaceAll('ё', 'е')
                .contains(query)) {
              return false;
            }
            if (_status != 'all' && t.status != _status) return false;
            return _dates == null ||
                overlapsDays(t, _dates!.start, _dates!.end);
          }).toList()..sort((a, b) => a.startsAt.compareTo(b.startsAt));
          final pages = (trips.length / _pageSize).ceil().clamp(1, 100000);
          final page = _page.clamp(0, pages - 1), start = page * _pageSize;
          final shown = trips.skip(start).take(_pageSize).toList();
          return Scaffold(
            appBar: AppBar(
              toolbarHeight: syncToolbarHeight(context),
              title: SyncPageTitle(title: 'Сплавы', controller: c),
              leading: Padding(
                padding: const EdgeInsets.all(6),
                child: Image.asset('assets/logo.jpg'),
              ),
              actions: [
                RefreshAction(controller: c),
                PopupMenuButton<String>(
                  tooltip: 'Аккаунт и справочники',
                  onSelected: (v) {
                    if (v == 'logout') _logout();
                    if (v == 'routes') {
                      showDialog<void>(
                        context: context,
                        builder: (_) => _RoutesDialog(controller: c),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(enabled: false, child: Text(widget.email)),
                    const PopupMenuItem(
                      value: 'routes',
                      child: Text('Маршруты'),
                    ),
                    const PopupMenuItem(
                      value: 'logout',
                      child: Text('Выйти из аккаунта'),
                    ),
                  ],
                ),
              ],
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                final wide =
                    constraints.maxWidth >= 1000 &&
                    MediaQuery.textScalerOf(context).scale(16) <= 24;
                final padding = wide ? 24.0 : 16.0;
                return PullToRefresh(
                  controller: c,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(padding, 20, padding, 0),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                runSpacing: 16,
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.allTrips
                                            ? 'Все сплавы'
                                            : 'Ближайшие сплавы',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        widget.allTrips
                                            ? 'Полный список · ${trips.length} выездов'
                                            : 'Выберите даты списка · календарь показывает все сплавы',
                                        style: const TextStyle(
                                          color: Color(0xff5a7285),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      if (c.hasPeople)
                                        OutlinedButton.icon(
                                          onPressed: () => Navigator.push(
                                            context,
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  PeopleScreen(controller: c),
                                            ),
                                          ),
                                          icon: const Icon(
                                            Icons.people_outline,
                                          ),
                                          label: const Text(
                                            'Люди',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      if (c.canCreateTrips)
                                        FilledButton.icon(
                                          onPressed: _create,
                                          icon: const Icon(Icons.add),
                                          label: const Text(
                                            'Создать выезд',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Wrap(
                                        alignment: WrapAlignment.spaceBetween,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 16,
                                        runSpacing: 16,
                                        children: [
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              ChoiceChip(
                                                label: const Text('Список'),
                                                avatar: const Icon(
                                                  Icons.table_rows_outlined,
                                                  size: 18,
                                                ),
                                                selected: !_calendar,
                                                onSelected: (_) => setState(
                                                  () => _calendar = false,
                                                ),
                                              ),
                                              ChoiceChip(
                                                label: const Text('Календарь'),
                                                avatar: const Icon(
                                                  Icons.calendar_month_outlined,
                                                  size: 18,
                                                ),
                                                selected: _calendar,
                                                onSelected: (_) => setState(
                                                  () => _calendar = true,
                                                ),
                                              ),
                                            ],
                                          ),
                                          Wrap(
                                            spacing: 16,
                                            runSpacing: 6,
                                            children: [
                                              _Legend(
                                                _calendar
                                                    ? TripOccupancy
                                                          .nearCapacityForeground
                                                    : const Color(0xffffe8a3),
                                                'От 80%',
                                              ),
                                              _Legend(
                                                _calendar
                                                    ? TripOccupancy
                                                          .fullForeground
                                                    : const Color(0xffffccd3),
                                                'Заполнен / сверх лимита',
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      TextField(
                                        decoration: const InputDecoration(
                                          hintText:
                                              'Название, маршрут или ответственный',
                                          labelText: 'Поиск сплава',
                                          prefixIcon: Icon(Icons.search),
                                        ),
                                        onChanged: (v) => setState(() {
                                          _search = v;
                                          _page = 0;
                                        }),
                                      ),
                                      if (!_calendar)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 16,
                                          ),
                                          child: Wrap(
                                            spacing: 12,
                                            runSpacing: 12,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              SizedBox(
                                                width: 240,
                                                child:
                                                    DropdownButtonFormField<
                                                      String
                                                    >(
                                                      initialValue: _status,
                                                      isExpanded: true,
                                                      decoration:
                                                          const InputDecoration(
                                                            labelText:
                                                                'Состояние',
                                                          ),
                                                      items: [
                                                        const DropdownMenuItem(
                                                          value: 'all',
                                                          child: Text(
                                                            'Все состояния',
                                                          ),
                                                        ),
                                                        for (final s in [
                                                          'draft',
                                                          'open',
                                                          'closed',
                                                          'in_progress',
                                                          'completed',
                                                          'cancelled',
                                                        ])
                                                          DropdownMenuItem(
                                                            value: s,
                                                            child: Text(
                                                              tripStatusLabel(
                                                                s,
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                      onChanged: (v) =>
                                                          setState(() {
                                                            _status = v!;
                                                            _page = 0;
                                                          }),
                                                    ),
                                              ),
                                              OutlinedButton.icon(
                                                onPressed: _dateFilter,
                                                icon: const Icon(
                                                  Icons.date_range,
                                                ),
                                                label: Text(
                                                  _dates == null
                                                      ? 'Любые даты'
                                                      : '${_short(_dates!.start)} — ${_short(_dates!.end)}',
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                              if (_dates != null)
                                                TextButton(
                                                  onPressed: () => setState(() {
                                                    _dates = null;
                                                    _page = 0;
                                                  }),
                                                  child: const Text(
                                                    'Сбросить даты',
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                      if (_calendar)
                        SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: padding),
                          sliver: SliverToBoxAdapter(
                            child: TripCalendar(
                              key: ValueKey(_dates?.start),
                              initialDay: _dates?.start,
                              trips: c.trips,
                              controller: c,
                              today: today,
                              onOpen: _open,
                            ),
                          ),
                        )
                      else if (trips.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text('Сплавов по выбранным датам нет.'),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.all(padding),
                          sliver: SliverToBoxAdapter(
                            child: wide
                                ? _table(shown)
                                : Column(
                                    children: [for (final t in shown) _card(t)],
                                  ),
                          ),
                        ),
                      if (!_calendar && pages > 1)
                        SliverToBoxAdapter(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              TextButton(
                                onPressed: page > 0
                                    ? () => setState(() => _page--)
                                    : null,
                                child: const Text('Назад'),
                              ),
                              Text('${page + 1} / $pages'),
                              TextButton(
                                onPressed: page + 1 < pages
                                    ? () => setState(() => _page++)
                                    : null,
                                child: const Text('Далее'),
                              ),
                            ],
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _table(List<Trip> trips) => DataTable(
    dataRowMinHeight: 80,
    dataRowMaxHeight: 96,
    headingRowHeight: 52,
    columns: const [
      DataColumn(label: Text('Сплав / маршрут')),
      DataColumn(label: Flexible(child: Text('Даты и дни недели'))),
      DataColumn(label: Text('Участники')),
      DataColumn(label: Text('Стоимость'), numeric: true),
      DataColumn(label: Text('Состояние')),
      DataColumn(label: Flexible(child: Text('На устройстве'))),
    ],
    rows: trips.map(_row).toList(),
  );
  DataRow _row(Trip trip) {
    final value = TripOccupancy.read(widget.controller, trip);
    return DataRow(
      color: WidgetStatePropertyAll(
        trip.capacityKnown && value.booked >= trip.capacity * .8
            ? value.background(trip)
            : Colors.white,
      ),
      cells: [
        DataCell(
          SizedBox(
            width: 240,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trip.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  trip.route,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff5c7487),
                  ),
                ),
              ],
            ),
          ),
          onTap: () => _open(trip),
        ),
        DataCell(
          SizedBox(
            width: 230,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tripDates(trip),
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Старт ${tripTime(trip)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff5c7487),
                  ),
                ),
              ],
            ),
          ),
          onTap: () => _open(trip),
        ),
        DataCell(
          OccupancyBadge(trip: trip, value: value),
          onTap: () => _open(trip),
        ),
        DataCell(
          Text(
            tripMoney(trip.basePriceKopecks),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => _open(trip),
        ),
        DataCell(
          SizedBox(width: 145, child: TripStateLabel(trip: trip)),
          onTap: () => _open(trip),
        ),
        DataCell(
          Tooltip(
            message: trip.isDownloaded
                ? 'Доступно без сети'
                : 'Состав загрузится при открытии',
            child: Icon(
              trip.isDownloaded
                  ? Icons.offline_pin_outlined
                  : Icons.cloud_download_outlined,
              color: trip.isDownloaded
                  ? const Color(0xff087f83)
                  : const Color(0xff8c9eac),
            ),
          ),
          onTap: () => _open(trip),
        ),
      ],
    );
  }

  Widget _card(Trip trip) {
    final value = TripOccupancy.read(widget.controller, trip);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(trip),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      trip.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                trip.route,
                style: const TextStyle(color: Color(0xff5a7285)),
              ),
              const SizedBox(height: 12),
              Text(
                tripDates(trip),
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Старт ${tripTime(trip)} · ${tripMoney(trip.basePriceKopecks)}',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OccupancyBadge(trip: trip, value: value),
                  TripStateLabel(trip: trip),
                  TextButton(
                    onPressed: () => _open(trip),
                    child: const Text('Открыть'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _short(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}';

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xff587184)),
        ),
      ),
    ],
  );
}

class _RoutesDialog extends StatefulWidget {
  const _RoutesDialog({required this.controller});
  final Stage1Controller controller;
  @override
  State<_RoutesDialog> createState() => _RoutesDialogState();
}

class _RoutesDialogState extends State<_RoutesDialog> {
  final _name = TextEditingController();
  String? _teamId;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _teamId = widget.controller.teams.where((t) => t.canCreate).firstOrNull?.id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty || _teamId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.createRoute(_name.text.trim(), teamId: _teamId!);
      _name.clear();
    } catch (_) {
      _error = 'Не удалось сохранить маршрут.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => AlertDialog(
      title: const Text('Маршруты'),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.controller.routes.isEmpty)
              const Text('Маршрутов пока нет.'),
            for (final route in widget.controller.routes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(route.name),
              ),
            if (_teamId != null) ...[
              const Divider(),
              DropdownButtonFormField<String>(
                initialValue: _teamId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Команда'),
                items: widget.controller.teams
                    .where((t) => t.canCreate)
                    .map(
                      (t) => DropdownMenuItem(value: t.id, child: Text(t.name)),
                    )
                    .toList(),
                onChanged: _busy ? null : (v) => _teamId = v,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                maxLength: 150,
                decoration: const InputDecoration(
                  labelText: 'Название маршрута',
                ),
                onSubmitted: (_) => _create(),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _create,
                child: const Text('Добавить маршрут'),
              ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Готово'),
        ),
      ],
    ),
  );
}
