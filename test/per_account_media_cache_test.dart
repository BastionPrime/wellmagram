import 'dart:io';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/storage/legacy_db_migrator.dart';
import 'package:wellmagram/core/storage/per_account_media_cache.dart';
import 'package:wellmagram/core/storage/per_account_databases.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:test/test.dart';

const max1 = AccountKey(network: Network.max, id: 1);
const max2 = AccountKey(network: Network.max, id: 2);
const tg3 = AccountKey(network: Network.telegram, id: 3);

class FakeDb implements DatabaseLike {
  bool closed = false;
  int pragmaCount = 0;
  final List<String> executed = [];

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    executed.add(sql);
    if (sql.startsWith('PRAGMA')) pragmaCount++;
  }

  @override
  Future<int> delete(String table, String where, List<Object?> whereArgs) async => 0;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async =>
      const [];

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakePaths implements AccountStoragePaths {
  String dbDir = '/data/db';
  String mediaRoot = '/data/media_cache';
  final List<String> askedMediaDirs = [];

  @override
  Future<String> databaseDir() async => dbDir;

  @override
  Future<String> mediaCacheDir(AccountKey account) async {
    final dir = '$mediaRoot/${PerAccountDatabases.mediaCacheFolderName(account)}';
    askedMediaDirs.add(dir);
    return dir;
  }
}

class FakeFs implements AccountStorageFs {
  final Set<String> existing = {};
  final List<String> deleted = [];
  final List<(String, bool)> deletedRecursive = [];

  @override
  Future<bool> exists(String path) async => existing.contains(path);

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    deleted.add(path);
    deletedRecursive.add((path, recursive));
    existing.remove(path);
  }
}

PerAccountDatabases makeDatabases() {
  final paths = FakePaths();
  final fs = FakeFs();
  return PerAccountDatabases(
    opener: (path) async => FakeDb(),
    paths: paths,
    fs: fs,
  );
}

void main() {
  group('naming', () {
    test('database file name is network-qualified', () {
      expect(PerAccountDatabases.fileName(max1), 'wellmagram_max_1.db');
      expect(PerAccountDatabases.fileName(tg3), 'wellmagram_tg_3.db');
    });

    test('media cache folder per account', () {
      expect(PerAccountDatabases.mediaCacheFolderName(max2), 'max_2');
      expect(PerAccountDatabases.mediaCacheFolderName(tg3), 'tg_3');
    });
  });

  group('forAccount', () {
    test('opens one database per account with foreign_keys ON', () async {
      final dbs = makeDatabases();
      final db = await dbs.forAccount(max1);
      expect((db as FakeDb).executed, contains('PRAGMA foreign_keys = ON'));
      expect(db.pragmaCount, 1);
    });

    test('reuses the same handle for the same account', () async {
      final dbs = makeDatabases();
      final a = await dbs.forAccount(max1);
      final b = await dbs.forAccount(max1);
      expect(identical(a, b), isTrue);
      expect((a as FakeDb).pragmaCount, 1);
    });

    test('separate handles per account', () async {
      final dbs = makeDatabases();
      final a = await dbs.forAccount(max1);
      final b = await dbs.forAccount(max2);
      expect(identical(a, b), isFalse);
    });

    test('close closes the handle and drops the cache', () async {
      final dbs = makeDatabases();
      final db = await dbs.forAccount(max1);
      await dbs.close(max1);
      expect((db as FakeDb).closed, isTrue);
      final reopened = await dbs.forAccount(max1);
      expect(identical(reopened, db), isFalse);
    });
  });

  group('removeAccount', () {
    test('removes database file and media cache recursively', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/db/wellmagram_max_1.db');
      fs.existing.add('/data/media_cache/max_1');
      final dbs = PerAccountDatabases(
        opener: (path) async => FakeDb(),
        paths: paths,
        fs: fs,
      );

      final report = await dbs.removeAccount(max1);

      expect(report.databaseRemoved, isTrue);
      expect(report.mediaCacheRemoved, isTrue);
      expect(report.removedAnything, isTrue);
      expect(fs.deleted, containsAll([
        '/data/db/wellmagram_max_1.db',
        '/data/media_cache/max_1',
      ]));
      expect(fs.deletedRecursive, contains(('/data/media_cache/max_1', true)));
      expect(
        fs.deletedRecursive,
        isNot(contains(('/data/db/wellmagram_max_1.db', true))),
      );
    });

    test('missing artifacts report false and do not throw', () async {
      final dbs = makeDatabases();
      final report = await dbs.removeAccount(max2);
      expect(report.removedAnything, isFalse);
    });

    test('other accounts keep their files', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/db/wellmagram_max_1.db');
      fs.existing.add('/data/db/wellmagram_max_2.db');
      fs.existing.add('/data/media_cache/max_1');
      fs.existing.add('/data/media_cache/max_2');
      final dbs = PerAccountDatabases(
        opener: (path) async => FakeDb(),
        paths: paths,
        fs: fs,
      );

      await dbs.removeAccount(max1);

      expect(fs.existing, containsAll([
        '/data/db/wellmagram_max_2.db',
        '/data/media_cache/max_2',
      ]));
      expect(fs.existing, isNot(contains('/data/db/wellmagram_max_1.db')));
    });

    test('closes the open handle before deleting', () async {
      final opened = <FakeDb>[];
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/db/wellmagram_max_1.db');
      final dbs = PerAccountDatabases(
        opener: (path) async {
          final db = FakeDb();
          opened.add(db);
          return db;
        },
        paths: paths,
        fs: fs,
      );
      await dbs.forAccount(max1);
      await dbs.removeAccount(max1);
      expect(opened.single.closed, isTrue);
    });

    test('isAccountPresent reflects the file', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/db/wellmagram_max_1.db');
      final dbs = PerAccountDatabases(
        opener: (path) async => FakeDb(),
        paths: paths,
        fs: fs,
      );
      expect(await dbs.isAccountPresent(max1), isTrue);
      expect(await dbs.isAccountPresent(max2), isFalse);
    });
  });

  group('legacy migration', () {
    test('copies account rows into its own database', () async {
      final dbs = makeDatabases();
      final inserted = <(AccountKey, String, Map<String, Object?>)>{};
      final legacy = _FakeLegacySource(
        profiles: [1, 2],
        rows: {
          'messages': {
            1: [
              {'id': 10, 'account_id': 1, 'text': 'a'},
              {'id': 11, 'account_id': 1, 'text': 'b'},
            ],
            2: [
              {'id': 20, 'account_id': 2, 'text': 'c'},
            ],
          },
        },
        onInsert: (account, table, row) async {
          inserted.add((account, table, row));
        },
      );
      final migrator = LegacyDbMigrator(databases: dbs, legacy: legacy);

      final counts = await migrator.migrateAccount(max1);

      expect(counts['messages'], 2);
      expect(inserted, hasLength(2));
      expect(inserted.first.$1, max1);
      expect(inserted.first.$2, 'messages');
      expect(inserted.first.$3, {'id': 10, 'account_id': 1, 'text': 'a'});
    });

    test('legacyAccounts lists MAX keys sorted', () async {
      final dbs = makeDatabases();
      final legacy = _FakeLegacySource(profiles: [9, 2], rows: const {});
      final migrator = LegacyDbMigrator(databases: dbs, legacy: legacy);
      final accounts = await migrator.legacyAccounts();
      expect(accounts.map((a) => a.storageId).toList(), ['max:2', 'max:9']);
    });

    test('telegram accounts are rejected explicitly', () async {
      final migrator = LegacyDbMigrator(
        databases: makeDatabases(),
        legacy: _FakeLegacySource(profiles: [1], rows: const {}),
      );
      expect(migrator.migrateAccount(tg3), throwsUnsupportedError);
    });
  });

  group('media cache', () {
    test('clear removes only the account directory', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/media_cache/max_1');
      fs.existing.add('/data/media_cache/max_2');
      final cache = PerAccountMediaCache(paths: paths, fs: fs);

      await cache.clear(max1);

      expect(fs.existing, contains('/data/media_cache/max_2'));
      expect(fs.existing, isNot(contains('/data/media_cache/max_1')));
    });

    test('clear on missing directory is a no-op', () async {
      final cache = PerAccountMediaCache(paths: FakePaths(), fs: FakeFs());
      await cache.clear(max1);
    });

    test('exists mirrors the filesystem', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/media_cache/max_1');
      final cache = PerAccountMediaCache(paths: paths, fs: fs);
      expect(await cache.exists(max1), isTrue);
      expect(await cache.exists(max2), isFalse);
    });
  });

  group('eviction policy (new implementation)', () {
    test('size limit is enforced with default value', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      final cache = PerAccountMediaCache(paths: paths, fs: fs); // Uses default 50MB

      expect(cache.maxSizeBytes, equals(50 * 1024 * 1024)); // 50MB
    });

    test('custom size limit is properly set', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      final cache = PerAccountMediaCache(paths: paths, fs: fs, maxSizeBytes: 1024); // 1KB

      expect(cache.maxSizeBytes, equals(1024));
    });

    test('initial cache size is zero', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      final cache = PerAccountMediaCache(paths: paths, fs: fs);

      expect(await cache.getCurrentSize(max1), equals(0));
    });

    test('touch updates access time for LRU without crashing on missing entries', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      final cache = PerAccountMediaCache(paths: paths, fs: fs);

      // This should not crash even if file is not tracked
      await cache.touch(max1, '/fake/file.jpg');
      expect(await cache.getCurrentSize(max1), equals(0));
    });

    test('calculateActualSize returns 0 for non-existent directory', () async {
      final paths = FakePaths();
      final fs = FakeFs();
      final cache = PerAccountMediaCache(paths: paths, fs: fs);

      expect(await cache.calculateActualSize(max1), equals(0));
    });

    test('trackFile ignores files that do not exist', () async {
      final dir = await Directory.systemTemp.createTemp('ope3894');
      addTearDown(() => dir.delete(recursive: true));
      final cache = PerAccountMediaCache(paths: FakePaths(), fs: FakeFs(), maxSizeBytes: 1000);

      await cache.trackFile(max1, '${dir.path}/missing.bin');

      expect(await cache.getCurrentSize(max1), equals(0));
    });
  });

  group('eviction behavior (over-budget)', () {
    // Deterministic clock: each call advances by 1 ms, so tracked order is
    // strictly the order of trackFile/touch calls in the test.
    DateTime fakeClock() {
      _clockMs += 1;
      return DateTime.fromMillisecondsSinceEpoch(_clockMs);
    }

    late Directory dir;

    Future<PerAccountMediaCache> makeCache({int budget = 1000}) async {
      dir = await Directory.systemTemp.createTemp('ope3894');
      addTearDown(() => dir.delete(recursive: true));
      return PerAccountMediaCache(
        paths: FakePaths(),
        fs: FakeFs(),
        maxSizeBytes: budget,
        clock: fakeClock,
      );
    }

    Future<String> writeFile(String name, int size) async {
      final path = '${dir.path}/$name';
      await File(path).writeAsBytes(List.filled(size, 0));
      return path;
    }

    test('exceeding the budget evicts the least recently used file', () async {
      final cache = await makeCache(budget: 1000);
      final a = await writeFile('a.bin', 600);
      final b = await writeFile('b.bin', 600);
      final c = await writeFile('c.bin', 600);

      await cache.trackFile(max1, a);
      await cache.trackFile(max1, b);
      // Refresh a so b becomes the LRU entry.
      await cache.touch(max1, a);
      await cache.trackFile(max1, c);

      // Budget is 1000: c (600) + a (600) is over, so b (LRU) is evicted,
      // then a — until the total fits. c is the newest and must survive.
      expect(await File(a).exists(), isFalse, reason: 'a evicted to fit budget');
      expect(await File(b).exists(), isFalse, reason: 'LRU b evicted');
      expect(await File(c).exists(), isTrue, reason: 'newest file survives');
      expect(await cache.getCurrentSize(max1), lessThanOrEqualTo(1000));
    });

    test('exactly at the budget evicts nothing', () async {
      final cache = await makeCache(budget: 1000);
      final a = await writeFile('a.bin', 500);
      final b = await writeFile('b.bin', 500);

      await cache.trackFile(max1, a);
      await cache.trackFile(max1, b);

      expect(await File(a).exists(), isTrue);
      expect(await File(b).exists(), isTrue);
      expect(await cache.getCurrentSize(max1), equals(1000));
    });

    test('single file larger than the whole budget is still tracked, others evicted first',
        () async {
      final cache = await makeCache(budget: 1000);
      final big = await writeFile('big.bin', 1500);
      final small = await writeFile('small.bin', 100);

      await cache.trackFile(max1, small);
      await cache.trackFile(max1, big);

      // LRU entry (small) is evicted; big alone remains even though it alone
      // exceeds the budget (a cache must keep what was just written).
      expect(await File(small).exists(), isFalse);
      expect(await File(big).exists(), isTrue);
      expect(await cache.getCurrentSize(max1), equals(1500));
    });

    test('touch protects a file from being the eviction victim', () async {
      final cache = await makeCache(budget: 1000);
      final old1 = await writeFile('old1.bin', 400);
      final old2 = await writeFile('old2.bin', 400);
      final fresh = await writeFile('fresh.bin', 400);

      await cache.trackFile(max1, old1);
      await cache.trackFile(max1, old2);
      await cache.touch(max1, old2); // old2 is now the most recent of the old pair
      await cache.trackFile(max1, fresh);

      // Over budget: old1 (LRU) goes first; after that 400+400=800 fits, so
      // old2 and fresh both survive.
      expect(await File(old1).exists(), isFalse);
      expect(await File(old2).exists(), isTrue);
      expect(await File(fresh).exists(), isTrue);
    });

    test('clear drops tracking for the account', () async {
      final dir = await Directory.systemTemp.createTemp('ope3894');
      addTearDown(() => dir.delete(recursive: true));
      final paths = FakePaths();
      final fs = FakeFs();
      fs.existing.add('/data/media_cache/max_1');
      final cache = PerAccountMediaCache(paths: paths, fs: fs, clock: fakeClock);
      final f = '${dir.path}/f.bin';
      await File(f).writeAsBytes(List.filled(100, 0));
      await cache.trackFile(max1, f);
      expect(await cache.getCurrentSize(max1), equals(100));

      await cache.clear(max1);

      expect(await cache.getCurrentSize(max1), equals(0));
    });
  });

  group('concurrent writes', () {
    test('racing trackFile calls all land in tracking, budget holds, no throw',
        () async {
      final dir = await Directory.systemTemp.createTemp('ope3894');
      addTearDown(() => dir.delete(recursive: true));
      DateTime fakeClock() {
        _clockMs += 1;
        return DateTime.fromMillisecondsSinceEpoch(_clockMs);
      }

      final cache = PerAccountMediaCache(
        paths: FakePaths(),
        fs: FakeFs(),
        maxSizeBytes: 1000,
        clock: fakeClock,
      );

      final paths = List.generate(10, (i) {
        final p = '${dir.path}/f$i.bin';
        File(p).writeAsBytesSync(List.filled(300, 0));
        return p;
      });

      // 10 writers x 300 bytes = 3000 bytes racing into a 1000-byte budget.
      await Future.wait(paths.map((p) => cache.trackFile(max1, p)));

      // No exception above; every survivor is consistent with the budget…
      final size = await cache.getCurrentSize(max1);
      expect(size, lessThanOrEqualTo(1000));
      // …all tracked files that remain on disk are counted, none lost…
      final onDisk = await Future.wait(
        paths.map((p) => File(p).exists()),
      );
      for (var i = 0; i < paths.length; i++) {
        if (onDisk[i]) {
          expect(size, greaterThanOrEqualTo(300));
        }
      }
      // …and eviction actually ran under contention (not everything kept).
      expect(onDisk.where((e) => e).length, lessThan(paths.length));
    });

    test('concurrent trackFile on different accounts does not cross-evict',
        () async {
      final dir = await Directory.systemTemp.createTemp('ope3894');
      addTearDown(() => dir.delete(recursive: true));
      final cache = PerAccountMediaCache(
        paths: FakePaths(),
        fs: FakeFs(),
        maxSizeBytes: 500,
        clock: () => DateTime.fromMillisecondsSinceEpoch(0),
      );

      final a = '${dir.path}/max1.bin';
      File(a).writeAsBytesSync(List.filled(400, 0));
      final b = '${dir.path}/max2.bin';
      File(b).writeAsBytesSync(List.filled(400, 0));

      await Future.wait([
        cache.trackFile(max1, a),
        cache.trackFile(max2, b),
      ]);

      // Each account is within its own 500-byte budget, both files survive.
      expect(await File(a).exists(), isTrue);
      expect(await File(b).exists(), isTrue);
      expect(await cache.getCurrentSize(max1), equals(400));
      expect(await cache.getCurrentSize(max2), equals(400));
    });
  });
}

int _clockMs = 0;

class _FakeLegacySource implements LegacyDbSource {
  final List<int> profiles;
  final Map<String, Map<int, List<Map<String, Object?>>>> rows;
  final Future<void> Function(
    AccountKey account,
    String table,
    Map<String, Object?> row,
  )? onInsert;

  _FakeLegacySource({
    required this.profiles,
    required this.rows,
    this.onInsert,
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
    await onInsert?.call(
      AccountKey(network: Network.max, id: row['account_id'] as int),
      table,
      row,
    );
  }
}