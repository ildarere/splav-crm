import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase/supabase.dart';

import '../core/prototype_database.dart';
import '../core/session_store.dart';
import '../core/stage1_api.dart';
import '../core/stage1_controller.dart';
import '../core/stage1_database.dart';
import '../core/people_api.dart';
import '../features/trips/trips_screen.dart';
import 'app_theme.dart';
import 'sync_widgets.dart';

class Stage1App extends StatefulWidget {
  const Stage1App({
    super.key,
    required this.url,
    required this.anonKey,
    required this.profile,
    this.legacyGroupId = '00000000-0000-4000-8000-000000000001',
  });

  final String url;
  final String anonKey;
  final String profile;
  final String legacyGroupId;

  @override
  State<Stage1App> createState() => _Stage1AppState();
}

class _Stage1AppState extends State<Stage1App> with WidgetsBindingObserver {
  SupabaseClient? _client;
  SessionStore? _store;
  Stage1Controller? _controller;
  StreamSubscription<AuthState>? _authEvents;
  Future<void> _storeWrites = Future.value();
  bool _loading = true;
  bool _reauthenticate = false;
  bool _closingAccount = false;
  String? _error;
  String? _email;
  String? _userId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
  }

  Future<void> _storeSession(Session? session) {
    final json = session == null ? null : jsonEncode(session.toJson());
    final write = _storeWrites.then((_) async {
      if (json == null) {
        await _store!.delete();
      } else {
        await _store!.write(json);
      }
    });
    _storeWrites = write.catchError((Object _) {});
    return write;
  }

  Future<void> _restore() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        widget.anonKey.isEmpty) {
      setState(() {
        _loading = false;
        _error =
            'Для запуска задайте SUPABASE_URL и SUPABASE_ANON_KEY. Пример конфигурации находится в README.';
      });
      return;
    }
    _client = SupabaseClient(
      widget.url,
      widget.anonKey,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    _store = SessionStore(scope: [widget.url, widget.profile].join('\n'));
    try {
      final stored = await _store!.read();
      if (stored != null) {
        try {
          await _client!.auth.setInitialSession(stored);
        } catch (_) {
          await _store!.delete();
        }
      }
      _authEvents = _client!.auth.onAuthStateChange.listen(
        (event) {
          if (event.event == AuthChangeEvent.signedOut) {
            unawaited(_storeSession(null).catchError((Object _) {}));
          } else if (event.event == AuthChangeEvent.tokenRefreshed) {
            unawaited(_storeSession(event.session).catchError((Object _) {}));
          }
        },
        onError: (Object error, StackTrace stack) {
          // The sync controller presents refresh errors, including late retries.
        },
      );
      final session = _client!.auth.currentSession;
      if (session != null) await _openAccount(session.user.email!);
    } catch (_) {
      _error =
          'Не удалось открыть защищённый сеанс. Проверьте доступ к хранилищу устройства.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _prepare() async {
    final session = _client!.auth.currentSession;
    try {
      if (session == null) throw const AuthException('Session expired');
      if (_userId != null && session.user.id != _userId) {
        throw const AuthException('Account changed');
      }
      if (!session.isExpired) return;
      await _client!.auth.refreshSession().timeout(const Duration(seconds: 8));
      await _storeSession(_client!.auth.currentSession);
    } on AuthRetryableFetchException {
      rethrow;
    } on AuthException {
      await _storeSession(null);
      if (mounted) setState(() => _reauthenticate = true);
      rethrow;
    }
  }

  Future<void> _openAccount(String email) async {
    final database = await PrototypeDatabase.open(
      scope: [
        widget.url,
        email.toLowerCase(),
        widget.legacyGroupId,
        widget.profile,
      ].join('\n'),
    );
    final controller = Stage1Controller(
      database,
      SupabaseStage1Api(client: _client!, prepare: _prepare),
      peopleApi: SupabasePeopleApi(_client!),
    );
    try {
      await database.bindAccountOwner(_client!.auth.currentUser!.id);
      await controller.initialize();
    } catch (_) {
      await controller.close();
      rethrow;
    }
    if (!mounted) {
      await controller.close();
      return;
    }
    _controller = controller;
    _email = email;
    _userId = _client!.auth.currentUser?.id;
  }

  Future<void> _login(String email, String password) async {
    if (_controller != null && email.toLowerCase() != _email?.toLowerCase()) {
      setState(() => _error = 'Для продолжения войдите в тот же аккаунт.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _client!.auth
          .signInWithPassword(email: email, password: password)
          .timeout(const Duration(seconds: 10));
      final session = response.session;
      if (session == null) throw const AuthException('Session missing');
      if (_controller != null && session.user.id != _userId) {
        throw const AuthException('Account changed');
      }
      await _storeSession(session);
      if (_controller == null) {
        await _openAccount(session.user.email!);
      } else {
        unawaited(_controller!.sync());
      }
      _reauthenticate = false;
    } on AuthException {
      _error = 'Не удалось войти. Проверьте почту и пароль.';
    } on TimeoutException {
      _error = 'Сервер не ответил. Проверьте подключение и повторите вход.';
    } catch (_) {
      _error =
          'Вход прервался. Проверьте подключение и доступ к хранилищу устройства.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _logout() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      setState(() => _closingAccount = true);
      await controller.clearAccountData();
      await _storeSession(null);
      await controller.close();
      try {
        await _client!.auth
            .signOut(scope: SignOutScope.local)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Local account data and remembered session have already been removed.
      }
      if (mounted) {
        setState(() {
          _controller = null;
          _email = null;
          _userId = null;
          _reauthenticate = false;
          _error = null;
        });
      }
    } finally {
      if (mounted) setState(() => _closingAccount = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_reauthenticate) {
      unawaited(_controller?.sync());
    }
  }

  Future<void> _close() async {
    await _controller?.close();
    await _authEvents?.cancel();
    await _storeWrites;
    await _client?.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return MaterialApp(
      title: 'Сплавы',
      locale: const Locale('ru', 'RU'),
      supportedLocales: const [Locale('ru', 'RU')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: splavTheme(),
      builder: (context, child) => controller == null
          ? child!
          : SyncRefreshScope(controller: controller, child: child!),
      home: _closingAccount
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : controller != null && !_reauthenticate
          ? TripsScreen(
              controller: controller,
              email: _email!,
              onLogout: _logout,
            )
          : _LoginScreen(
              configured: _client != null,
              busy: _loading,
              error: _error,
              email: _reauthenticate ? _email : null,
              onLogin: _login,
            ),
    );
  }
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({
    required this.configured,
    required this.busy,
    required this.error,
    required this.email,
    required this.onLogin,
  });
  final bool configured;
  final bool busy;
  final String? error;
  final String? email;
  final Future<void> Function(String, String) onLogin;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  Future<void> _submit() async {
    if (widget.busy || !(_form.currentState?.validate() ?? false)) return;
    final password = _password.text;
    _password.clear();
    await widget.onLogin(widget.email ?? _email.text.trim(), password);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.kayaking_rounded,
                      size: 52,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Сплавы',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.email == null
                          ? 'Войдите в аккаунт организатора'
                          : 'Подтвердите вход, чтобы продолжить обмен. Локальные правки сохранены.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    if (widget.configured) ...[
                      if (widget.email != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(widget.email!),
                        )
                      else
                        TextFormField(
                          controller: _email,
                          autofillHints: const [AutofillHints.username],
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          enabled: !widget.busy,
                          decoration: const InputDecoration(
                            labelText: 'Электронная почта',
                          ),
                          validator: (v) => (v ?? '').trim().contains('@')
                              ? null
                              : 'Введите электронную почту',
                        ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        enabled: !widget.busy,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Пароль',
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            tooltip: _obscure
                                ? 'Показать пароль'
                                : 'Скрыть пароль',
                          ),
                        ),
                        validator: (v) =>
                            (v ?? '').isEmpty ? 'Введите пароль' : null,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: widget.busy ? null : _submit,
                        child: const Text('Войти'),
                      ),
                    ],
                    if (widget.busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (widget.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          widget.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
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
  }
}
