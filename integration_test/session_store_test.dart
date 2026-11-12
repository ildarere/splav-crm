import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splav/core/session_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'OS session storage survives reopening and is isolated by scope',
    (tester) async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final scope = 'native-storage-acceptance-$suffix';
      final store = SessionStore(scope: scope);
      final other = SessionStore(scope: '$scope-other');
      addTearDown(store.delete);
      addTearDown(other.delete);
      expect(await store.read(), isNull);
      await store.write('{"test":"сеанс","version":1}');
      expect(
        await SessionStore(scope: scope).read(),
        '{"test":"сеанс","version":1}',
      );
      expect(await other.read(), isNull);
      await store.write('{"test":"обновлён","version":2}');
      expect(
        await SessionStore(scope: scope).read(),
        '{"test":"обновлён","version":2}',
      );
      await store.delete();
      expect(await store.read(), isNull);
    },
  );
}
