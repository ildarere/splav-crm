import 'dart:async';

import 'package:flutter/material.dart';

import '../core/prototype.dart';
import '../features/groups/group_screen.dart';

class PrototypeSession {
  const PrototypeSession(this.controller, this._disposeClient);

  final PrototypeController controller;
  final Future<void> Function() _disposeClient;

  Future<void> close() async {
    try {
      await controller.close();
    } finally {
      await _disposeClient();
    }
  }
}

class PrototypeApp extends StatefulWidget {
  const PrototypeApp({super.key, required this.open});

  final Future<PrototypeSession?> Function() open;

  @override
  State<PrototypeApp> createState() => _PrototypeAppState();
}

class _PrototypeAppState extends State<PrototypeApp>
    with WidgetsBindingObserver {
  late Future<PrototypeSession?> _opening;
  PrototypeSession? _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _opening = _open();
  }

  Future<PrototypeSession?> _open() async {
    final session = await widget.open();
    if (mounted) {
      _session = session;
    } else {
      await session?.close();
    }
    return session;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_session?.controller.sync());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Сплавы',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff006b62)),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: FutureBuilder<PrototypeSession?>(
        future: _opening,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return _LaunchMessage(
              icon: Icons.storage_rounded,
              title: 'Не удалось открыть данные',
              body: 'Попробуйте снова открыть локальную базу приложения.',
              action: FilledButton(
                onPressed: () => setState(() => _opening = _open()),
                child: const Text('Повторить'),
              ),
            );
          }
          final session = snapshot.data;
          if (session == null) {
            return const _LaunchMessage(
              icon: Icons.settings_outlined,
              title: 'Требуется настройка',
              body:
                  'Укажите адрес и публичный ключ Supabase, логин и пароль '
                  'тестового организатора. Пример запуска есть в README.',
            );
          }
          return GroupScreen(controller: session.controller);
        },
      ),
    );
  }
}

class _LaunchMessage extends StatelessWidget {
  const _LaunchMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сплавы')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 40),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(body, textAlign: TextAlign.center),
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
