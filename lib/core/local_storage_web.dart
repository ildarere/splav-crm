import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

Future<QueryExecutor> openLocalStorage(String key) async {
  final database = await WasmDatabase.open(
    databaseName: 'splav-$key',
    sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
    driftWorkerUri: Uri.base.resolve('drift_worker.js'),
  );
  if (database.chosenImplementation == WasmStorageImplementation.inMemory) {
    await database.resolvedExecutor.close();
    throw StateError('Браузер не разрешил сохранять данные приложения.');
  }
  return database.resolvedExecutor;
}
