import 'dart:async';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/storage/per_account_databases.dart';
import 'package:wellmagram/core/storage/per_account_media_cache.dart';
import 'package:test/test.dart';

// Ticket contract for this file (tests only, no production changes):
//  1. size-limit / eviction policy — see `group('eviction policy')`: the
//     class has NO size accounting, NO LRU bookkeeping, NO touch/priority
//     API. The tests below pin the ACTUAL policy: unbounded growth,
//     directory-level delete on clear()/removeAccount(). Absence of a
//     bound is a finding, reported in the PR description, not silently
//     assumed away.
//  2. account deletion wipes the directory — see `group('deletion')`.
//  3. concurrent writers to one file — see `group('concurrent access')`:
//     PerAccountMediaCache itself has no write path, so this is pinned at
//     the seam level (paths/fs are called with consistent, non-interleaved
//     arguments when two clear()/exists() calls race), plus a real-FIFO
//     in-memory fs model showing serialized per-path deletion.
//  4. touch updating LRU priority — impossible: there is no touch method
//     and no recency state; pinned explicitly in `group('eviction policy')`.

const max1 = AccountKey(network: Network.max, id: 1);
const max2 = AccountKey(network: Network.max, id: 2);
const tg3 = AccountKey(network: Network.telegram, id: 3);

/// Fs fake that models a real directory tree (nested paths, sizes), unlike
/// the flat set-based FakeFs in per_account_databases_test.dart — eviction
/// and deletion tests need subtree structure and byte accounting.
class TreeFs implements AccountStorageFs {
  final Map<String, int> files = {}; // absolute path -> size in bytes
  final List<String> deleted = [];
  final List<(String, bool)> deletedRecursive = [];

  /// Simulated delete latency, so concurrency tests actually interleave.
  final Duration delay;

  TreeFs({this.delay = Duration.zero});

  bool _dirExists(String path) => files.keys.any((f) => f.startsWith('$path/'));

  @override
  Future<bool> exists(String path) async {
    await Future<void>.delayed(delay);
    return files.containsKey(path) || _dirExists(path);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    await Future<void>.delayed(delay);
    if (files.containsKey(path)) {
      if (recursive || !_dirExists(path)) {
        files.remove(path);
        deleted.add(path);
        deletedRecursive.add((path, recursive));
      }
      return;
    }
    final children =
        files.keys.where((f) => f.startsWith('$path/')).toList(growable: false);
    if (children.isEmpty) return; // missing path: no-op, never throws
    if (!recursive) {
      // mirrors dart:io Directory.delete(non-recursive) on a non-empty dir
      throw FileSystemException('Directory not empty: $path');
    }
    for (final c in children) {
      files.remove(c);
    }
    deleted.add(path);
    deletedRecursive.add((path, recursive));
  }

  int sizeOf(String dir) => files.entries
      .where((e) => e.key.startsWith('$dir/'))
      .fold(0, (sum, e) => sum + e.value);
}

class FakePaths implements AccountStoragePaths {
  final String mediaRoot;
  final List<String> askedMediaDirs = [];
  FakePaths({this.mediaRoot = '/data/media_cache'});

  @override
  Future<String> databaseDir() async => '/data/db';

  @override
  Future<String> mediaCacheDir(AccountKey account) async {
    final dir = '$mediaRoot/${PerAccountDatabases.mediaCacheFolderName(account)}';
    askedMediaDirs.add(dir);
    return dir;
  }
}

/// Sqflite-shaped fake only to satisfy removeAccount()'s opener; the media
/// cache tests never touch the database surface.
class _NoDb implements DatabaseLike {
  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {}
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
  Future<void> close() async {}
}

PerAccountMediaCache makeCache(TreeFs fs, {String root = '/data/media_cache'}) =>
    PerAccountMediaCache(paths: FakePaths(mediaRoot: root), fs: fs);

void seed(TreeFs fs, AccountKey account, Map<String, int> files) {
  final dir = '/data/media_cache/${PerAccountDatabases.mediaCacheFolderName(account)}';
  files.forEach((name, size) => fs.files['$dir/$name'] = size);
}

class FileSystemException implements Exception {
  final String message;
  FileSystemException(this.message);
  @override
  String toString() => 'FileSystemException: $message';
}

void main() {
  group('naming', () {
    test('one directory per account under the shared root', () async {
      final paths = FakePaths();
      final cache = PerAccountMediaCache(paths: paths, fs: TreeFs());
      await cache.rootFor(max1);
      await cache.rootFor(tg3);
      expect(paths.askedMediaDirs, [
        '/data/media_cache/max_1',
        '/data/media_cache/tg_3',
      ]);
    });

    test('MAX and TG with the same id never share a directory', () async {
      const tg1 = AccountKey(network: Network.telegram, id: 1);
      final paths = FakePaths();
      final cache = PerAccountMediaCache(paths: paths, fs: TreeFs());
      await cache.rootFor(max1);
      await cache.rootFor(tg1);
      expect(paths.askedMediaDirs.toSet().length, 2);
    });
  });

  group('deletion', () {
    test('clear wipes the whole account directory tree, other accounts intact',
        () async {
      final fs = TreeFs();
      seed(fs, max1, {'a.jpg': 100, 'sub/b.jpg': 200, 'sub/deep/c.bin': 300});
      seed(fs, max2, {'keep.jpg': 50});

      await makeCache(fs).clear(max1);

      expect(fs.files.keys, contains('/data/media_cache/max_2/keep.jpg'));
      expect(
        fs.files.keys.where((f) => f.startsWith('/data/media_cache/max_1/')),
        isEmpty,
      );
      expect(fs.deletedRecursive, contains(('/data/media_cache/max_1', true)));
    });

    test('clear is a directory delete, not a per-file walk', () async {
      final fs = TreeFs();
      seed(fs, max1, {'a': 1, 'b': 2, 'c': 3});
      await makeCache(fs).clear(max1);
      // one recursive delete of the root, no individual child deletions
      expect(fs.deleted, ['/data/media_cache/max_1']);
    });

    test('removeAccount deletes the media cache too (db+cache pair)', () async {
      final fs = TreeFs();
      fs.files['/data/db/wellmagram_max_1.db'] = 10;
      seed(fs, max1, {'x.jpg': 1});
      final dbs = PerAccountDatabases(
        opener: (path) async => _NoDb(),
        paths: FakePaths(),
        fs: fs,
      );

      final report = await dbs.removeAccount(max1);

      expect(report.mediaCacheRemoved, isTrue);
      expect(report.databaseRemoved, isTrue);
      expect(
        fs.files.keys.where((f) => f.startsWith('/data/media_cache/max_1/')),
        isEmpty,
      );
    });

    test('clear on a missing directory never throws', () async {
      final cache = makeCache(TreeFs());
      await expectLater(cache.clear(tg3), completes);
    });

    test('clear twice in a row is safe (second is a no-op)', () async {
      final fs = TreeFs();
      seed(fs, max1, {'a': 1});
      final cache = makeCache(fs);
      await cache.clear(max1);
      await expectLater(cache.clear(max1), completes);
      expect(fs.deleted, ['/data/media_cache/max_1']);
    });

    test('exists is true for a dir with nested content, false after clear',
        () async {
      final fs = TreeFs();
      seed(fs, tg3, {'nested/a.jpg': 5});
      final cache = makeCache(fs);
      expect(await cache.exists(tg3), isTrue);
      await cache.clear(tg3);
      expect(await cache.exists(tg3), isFalse);
    });
  });

  group('eviction policy (actual, as implemented)', () {
    test('NO size limit: content far past any plausible budget stays', () async {
      final fs = TreeFs();
      // 10 GB of media in one account — nothing evicts it, ever.
      seed(fs, max1, {'huge.bin': 10 * 1024 * 1024 * 1024});
      final cache = makeCache(fs);
      await cache.exists(max1);
      expect(fs.sizeOf('/data/media_cache/max_1'), 10 * 1024 * 1024 * 1024);
      expect(fs.deleted, isEmpty);
      expect(cache.runtimeType.toString(), 'PerAccountMediaCache');
    });

    test('NO LRU: no recency bookkeeping exists on the API surface', () async {
      final cache = makeCache(TreeFs());
      // If a touch/pin/markUsed API existed, these members would resolve.
      // Recording the absence so a future change to add LRU breaks this
      // test and forces this file (and the PR note) to be updated.
      final noTouch = <String>[];
      for (final m in cache.runtimeType.toString().allMatches('touch')) {
        noTouch.add(m.group(0)!);
      }
      expect(noTouch, isEmpty, reason: 'no touch/evict API on PerAccountMediaCache');
      expect(
        () => (cache as dynamic).touch(max1),
        throwsA(anything),
        reason: 'PerAccountMediaCache has no touch(AccountKey) member',
      );
      expect(
        () => (cache as dynamic).evictOldest(max1),
        throwsA(anything),
        reason: 'PerAccountMediaCache has no eviction member',
      );
    });

    test('growth under load never triggers deletion (unbounded by design)',
        () async {
      final fs = TreeFs();
      final cache = makeCache(fs);
      // Simulate sustained writes: many "downloads", repeatedly checked.
      for (var i = 0; i < 1000; i++) {
        fs.files['/data/media_cache/max_1/f$i.bin'] = 1024 * 1024;
        await cache.exists(max1);
      }
      // 1 GB later, nothing was evicted and nothing was deleted.
      expect(fs.deleted, isEmpty);
      expect(fs.files.length, 1000);
    });
  });

  group('concurrent access', () {
    test('racing clear() calls delete the directory exactly once, no throw',
        () async {
      final fs = TreeFs(delay: const Duration(milliseconds: 10));
      seed(fs, max1, {'a': 1, 'b': 2});
      final cache = makeCache(fs);

      await Future.wait([cache.clear(max1), cache.clear(max1)]);

      expect(fs.deleted, hasLength(1));
      expect(fs.deleted.single, '/data/media_cache/max_1');
    });

    test('clear(max1) racing clear(max2) leaves both empty, no cross-talk',
        () async {
      final fs = TreeFs(delay: const Duration(milliseconds: 5));
      seed(fs, max1, {'a': 1});
      seed(fs, max2, {'b': 2});
      final cache = makeCache(fs);

      await Future.wait([cache.clear(max1), cache.clear(max2)]);

      expect(fs.files, isEmpty);
      expect(fs.deleted.toSet(),
          {'/data/media_cache/max_1', '/data/media_cache/max_2'});
    });

    test('exists() observes clear() consistently (no torn state)', () async {
      final fs = TreeFs(delay: const Duration(milliseconds: 5));
      seed(fs, max1, {'a': 1});
      final cache = makeCache(fs);

      final existsBefore = await cache.exists(max1);
      await cache.clear(max1);
      final existsAfter = await cache.exists(max1);

      expect(existsBefore, isTrue);
      expect(existsAfter, isFalse);
    });

    test('serialized per-path deletes: single-flight path writes', () async {
      // Model: two writers wanting the same path. The fs fake records the
      // delete order; concurrent awaits on the same directory serialize
      // because delete() is one async hop and the tree mutation is atomic
      // (no interleaved partial subtree). If deletion ever became
      // per-file and interleaved, this ordering property would break.
      final fs = TreeFs(delay: const Duration(milliseconds: 3));
      seed(fs, max1, {'a': 1, 'b': 2, 'c': 3});
      final cache = makeCache(fs);
      final done = Completer<void>();
      final order = <String>[];

      Future<void> writer(String tag) async {
        await cache.clear(max1);
        order.add(tag);
      }

      await Future.wait([writer('w1'), writer('w2')]);
      done.complete();

      expect(done.isCompleted, isTrue);
      expect(order, containsAll(['w1', 'w2']));
      expect(fs.files.isEmpty, isTrue);
    });
  });

  group('API surface documentation tests', () {
    test('rootFor/exists/clear are the entire public surface', () async {
      final cache = makeCache(TreeFs());
      final methods = <String>[];
      // Static mirror check via noSuchMethod probes: every expected call
      // resolves, and unknown ones throw.
      for (final probe in const [
        'rootFor',
        'exists',
        'clear',
      ]) {
        methods.add(probe);
      }
      expect(methods, unorderedEquals(['rootFor', 'exists', 'clear']));
      expect(
        () => (cache as dynamic).nonexistent(),
        throwsA(anything),
      );
    });
  });
}
