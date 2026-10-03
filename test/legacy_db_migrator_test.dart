import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/storage/legacy_db_migrator.dart';
import 'package:wellmagram/core/storage/per_account_databases.dart';
import 'package:test/test.dart';

const max1 = AccountKey(network: Network.max, id: 1);
const max2 = AccountKey(network: Network.max, id: 2);
const max3 = AccountKey(network: Network.max, id: 3);
const tg4 = AccountKey(network: Network.telegram, id: 4);

/// In-memory account database: rows keyed by table, no schema enforcement
/// (the migrator keeps the legacy table shape as-is, only the row filter
/// differs — plan-v3 Т-1.5).
class _MemDb implements DatabaseLike {
  final Map<String, List<Map<String, Object?>>> tables = {};
  final List<String> executed = [];
  bool closed = false;

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    executed.add(sql);
  }

  @override
  Future<int> delete(String table, String where, List<Object?> whereArgs) async =>
      0;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async =>
      List.of(tables[table] ?? const []);

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// In-memory legacy Komet source: `profile` ids + per-table rows keyed by
/// account_id. Can throw from [rowsFor] to emulate a damaged legacy DB.
class _LegacyDb implements LegacyDbSource {
  List<int> profiles;
  Map<String, Map<int, List<Map<String, Object?>>>> rows;

  _LegacyDb({
    this.profiles = const [],
    this.rows = const {},
  });

  @override
  Future<List<int>> profileAccountIds() async => List.of(profiles);

  @override
  Future<List<Map<String, Object?>>> rowsFor(String table, int accountId) async =>
      rows[table]?[accountId] ?? const [];

  @override
  Future<void> insertInto(
    DatabaseLike target,
    String table,
    Map<String, Object?> row,
  ) async {
    final db = target as _MemDb;
    final id = row['id'];
    // Damage check: `account_id` must be present and integer-like — a row
    // with a damaged account reference cannot be trusted and the target
    // insert rejects it.
    if (row['account_id'] is! num) {
      throw ArgumentError.value(row['account_id'], 'account_id',
          'corrupted legacy row');
    }
    final rows = db.tables.putIfAbsent(table, () => []);
    final index = rows.indexWhere((r) => r['id'] == id);
    if (index >= 0) {
      rows[index] = row;
    } else {
      rows.add(row);
    }
  }
}

void main() {
  late Map<String, _MemDb> dbsByPath;
  late Map<String, _MemDb> dbs;
  late PerAccountDatabases databases;

  setUp(() {
    dbsByPath = {};
    dbs = {};
    databases = PerAccountDatabases(
      opener: (path) async => dbsByPath.putIfAbsent(
        path,
        () => dbs.putIfAbsent(path, () => _MemDb()),
      ),
      paths: _FakePaths(),
      fs: _FakeFs(),
    );
  });

  LegacyDbMigrator migratorFor(_LegacyDb legacy) =>
      LegacyDbMigrator(databases: databases, legacy: legacy);

  group('empty legacy storage', () {
    test('legacyAccounts returns an empty list', () async {
      final migrator = migratorFor(_LegacyDb());
      expect(await migrator.legacyAccounts(), isEmpty);
    });

    test('migrateAccount copies zero rows and creates the database file',
        () async {
      final migrator = migratorFor(_LegacyDb(profiles: [1]));

      final counts = await migrator.migrateAccount(max1);

      expect(counts, {
        for (final t in const [
          'chats_cache',
          'contacts',
          'messages',
          'chat_participants',
          'sync_state',
        ])
          t: 0,
      });
      // The per-account database was opened (created) even with no rows.
      expect(dbsByPath.keys, contains('/data/db/wellmagram_max_1.db'));
    });
  });

  group('legacy with accounts', () {
    _LegacyDb threeAccounts() => _LegacyDb(
          profiles: [3, 1, 2],
          rows: {
            'messages': {
              1: [
                {'id': 11, 'account_id': 1, 'text': 'm-11'},
                {'id': 12, 'account_id': 1, 'text': 'm-12'},
              ],
              2: [
                {'id': 21, 'account_id': 2, 'text': 'm-21'},
              ],
              3: [
                {'id': 31, 'account_id': 3, 'text': 'm-31'},
              ],
            },
            'contacts': {
              1: [
                {'id': 101, 'account_id': 1, 'name': 'c-101'},
              ],
              3: [
                {'id': 301, 'account_id': 3, 'name': 'c-301'},
              ],
            },
          },
        );

    test('one account: rows land in its own database only', () async {
      final migrator = migratorFor(threeAccounts());

      final counts = await migrator.migrateAccount(max1);

      final db = dbs['/data/db/wellmagram_max_1.db']!;
      expect(db.tables['messages'], hasLength(2));
      expect(db.tables['contacts'], hasLength(1));
      expect(counts['messages'], 2);
      expect(counts['contacts'], 1);
      expect(counts['chats_cache'], 0);
      // Other accounts were not created or touched.
      expect(dbsByPath.keys, ['/data/db/wellmagram_max_1.db']);
    });

    test('three accounts: each database only has its own rows', () async {
      final migrator = migratorFor(threeAccounts());

      for (final account in await migrator.legacyAccounts()) {
        await migrator.migrateAccount(account);
      }

      expect(
        (dbs['/data/db/wellmagram_max_1.db']!.tables['messages'] ?? const [])
            .map((r) => r['id']),
        [11, 12],
      );
      expect(
        (dbs['/data/db/wellmagram_max_2.db']!.tables['messages'] ?? const [])
            .map((r) => r['id']),
        [21],
      );
      expect(
        (dbs['/data/db/wellmagram_max_3.db']!.tables['messages'] ?? const [])
            .map((r) => r['id']),
        [31],
      );
      expect(
        dbs['/data/db/wellmagram_max_2.db']!.tables['contacts'],
        isNull,
      );
      expect(
        dbs['/data/db/wellmagram_max_3.db']!.tables['contacts']!
            .map((r) => r['name']),
        ['c-301'],
      );
    });

    test('legacyAccounts lists MAX keys sorted regardless of profile order',
        () async {
      final migrator = migratorFor(threeAccounts());
      expect(
        (await migrator.legacyAccounts()).map((a) => a.storageId).toList(),
        ['max:1', 'max:2', 'max:3'],
      );
    });
  });

  group('damaged legacy storage', () {
    test('a damaged row is skipped with a log, migration continues', () async {
      final legacy = _LegacyDb(
        profiles: [1, 2],
        rows: {
          'messages': {
            1: [
              {'id': 11, 'account_id': 1, 'text': 'm-11'},
              // Damage: account_id column missing → row-level error.
              {'id': 12, 'text': 'corrupt'},
            ],
            2: [
              {'id': 21, 'account_id': 2, 'text': 'm-21'},
            ],
          },
        },
      );
      final migrator = migratorFor(legacy);

      final counts = await migrator.migrateAccount(max1);

      // Row 12 was skipped (logged), row 11 migrated.
      expect(counts['messages'], 1);
      final db = dbs['/data/db/wellmagram_max_1.db']!;
      expect(
        db.tables['messages']!.map((r) => r['id']),
        [11],
      );
    });

    test('a failing table read throws: partial damage must be visible',
        () async {
      final legacy = _LegacyDb(
        profiles: [1],
        rows: {
          'messages': {
            1: [
              {'id': 11, 'account_id': 1, 'text': 'm-11'},
            ],
          },
        },
      );
      final migrator = migratorFor(legacy);

      // chats_cache is the first table: emulate a damaged table read.
      final failing = _FailingLegacySource(legacy, failOnTable: 'chats_cache');
      final failingMigrator = LegacyDbMigrator(
        databases: databases,
        legacy: failing,
      );

      await expectLater(
        failingMigrator.migrateAccount(max1),
        throwsStateError,
      );
      // The intact migrator run above (chats_cache is the first table) never
      // got past the damaged read: no row was inserted before the failure —
      // the damage is visible, not silently swallowed.
      expect(dbs['/data/db/wellmagram_max_1.db']!.tables, isEmpty);
      // Sanity: the same source migrates fine when the table reads.
      await migrator.migrateAccount(max1);
      expect(
        dbs['/data/db/wellmagram_max_1.db']!.tables['messages']!
            .map((r) => r['id']),
        [11],
      );
    });
  });

  group('idempotent re-migration', () {
    test('re-migrating the same account does not duplicate rows', () async {
      final legacy = _LegacyDb(
        profiles: [1],
        rows: {
          'messages': {
            1: [
              {'id': 11, 'account_id': 1, 'text': 'm-11'},
              {'id': 12, 'account_id': 1, 'text': 'm-12'},
            ],
          },
        },
      );
      final migrator = migratorFor(legacy);

      final first = await migrator.migrateAccount(max1);
      final second = await migrator.migrateAccount(max1);

      final db = dbs['/data/db/wellmagram_max_1.db']!;
      expect(db.tables['messages'], hasLength(2));
      expect(
        db.tables['messages']!.map((r) => r['id']),
        [11, 12],
      );
      // Both passes report the legacy rows they saw.
      expect(first['messages'], 2);
      expect(second['messages'], 2);
      // The same handle is reused (no second open), insert-or-replace keeps
      // ids unique.
      expect(dbsByPath.length, 1);
    });

    test('legacy data stays in place — the source is never mutated',
        () async {
      final legacy = _LegacyDb(
        profiles: [1],
        rows: {
          'messages': {
            1: [
              {'id': 11, 'account_id': 1, 'text': 'm-11'},
            ],
          },
        },
      );
      final migrator = migratorFor(legacy);

      await migrator.migrateAccount(max1);
      await migrator.migrateAccount(max1);

      // Rollback safety: legacy rows survive two migrations untouched.
      expect(legacy.profiles, [1]);
      expect(legacy.rows['messages']![1], [
        {'id': 11, 'account_id': 1, 'text': 'm-11'},
      ]);
    });
  });

  group('network guards', () {
    test('telegram accounts are rejected explicitly', () async {
      final migrator = migratorFor(_LegacyDb(profiles: [1]));
      expect(migrator.migrateAccount(tg4), throwsUnsupportedError);
    });
  });
}

class _FailingLegacySource implements LegacyDbSource {
  final LegacyDbSource inner;
  final String failOnTable;

  _FailingLegacySource(this.inner, {required this.failOnTable});

  @override
  Future<List<int>> profileAccountIds() => inner.profileAccountIds();

  @override
  Future<List<Map<String, Object?>>> rowsFor(String table, int accountId) {
    if (table == failOnTable) {
      throw StateError('legacy db damaged: cannot read table $table');
    }
    return inner.rowsFor(table, accountId);
  }

  @override
  Future<void> insertInto(
    DatabaseLike target,
    String table,
    Map<String, Object?> row,
  ) =>
      inner.insertInto(target, table, row);
}

class _FakePaths implements AccountStoragePaths {
  @override
  Future<String> databaseDir() async => '/data/db';

  @override
  Future<String> mediaCacheDir(AccountKey account) async =>
      '/data/media_cache/${PerAccountDatabases.mediaCacheFolderName(account)}';
}

class _FakeFs implements AccountStorageFs {
  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<void> delete(String path, {bool recursive = false}) async {}
}
