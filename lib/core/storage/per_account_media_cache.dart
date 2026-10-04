/// Per-account media cache paths with size limit and eviction policy (plan-v3 Т-1.5: «кэш медиа per-account»).
///
/// Upstream MediaCache is one flat `media_cache` directory for all accounts;
/// wellmagram splits it per account so removal is a directory delete and
/// caches never mix.
///
/// This version adds size limits and eviction policies to prevent unlimited growth.
library;

import 'dart:io';
import 'dart:collection';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'per_account_databases.dart';

/// Injectable clock seam so LRU order is deterministic in tests.
typedef CacheClock = DateTime Function();

class CacheEntry {
  final String filePath;
  final int size;
  DateTime lastAccessed;

  CacheEntry(this.filePath, this.size, this.lastAccessed);
}

class PerAccountMediaCache {
  final AccountStoragePaths paths;
  final AccountStorageFs fs;
  final int maxSizeBytes; // Maximum size in bytes per account
  final CacheClock clock;

  // In-memory tracking of cache entries for LRU eviction
  final Map<AccountKey, LinkedHashMap<String, CacheEntry>> _cacheEntries = {};

  // Serializes per-account mutations (tracking + eviction) so concurrent
  // writers cannot interleave and produce torn bookkeeping.
  final Map<AccountKey, Future<void>> _accountLocks = {};

  PerAccountMediaCache({
    required this.paths,
    required this.fs,
    this.maxSizeBytes = 50 * 1024 * 1024, // Default 50MB per account
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  Future<String> rootFor(AccountKey account) => paths.mediaCacheDir(account);

  Future<bool> exists(AccountKey account) async =>
      fs.exists(await paths.mediaCacheDir(account));

  Future<void> clear(AccountKey account) async {
    final dir = await paths.mediaCacheDir(account);
    if (await fs.exists(dir)) {
      await fs.delete(dir, recursive: true);
    }

    // Clear in-memory tracking
    _cacheEntries.remove(account);
  }

  /// Adds a file to the cache tracking and evicts if necessary.
  /// Per-account operations are serialized: concurrent callers queue behind
  /// each other, so tracking and eviction never interleave.
  Future<void> trackFile(AccountKey account, String filePath) async {
    return _serialize(account, () async {
      final file = File(filePath);
      if (!await file.exists()) {
        // If file doesn't exist, we shouldn't track it
        return;
      }

      try {
        final stat = await file.stat();
        final size = stat.size;

        // Get or create cache entries for this account
        final entries = _cacheEntries.putIfAbsent(account, () => LinkedHashMap<String, CacheEntry>());

        // Add new entry
        entries[filePath] = CacheEntry(filePath, size, clock());

        // Check if we exceed the size limit and evict if necessary
        await _enforceSizeLimit(account);
      } on FileSystemException {
        // If we can't stat the file, don't track it
        return;
      }
    });
  }

  /// Runs [action] exclusively for [account]: later callers await the chain
  /// of earlier ones instead of racing them.
  Future<void> _serialize(AccountKey account, Future<void> Function() action) {
    final previous = _accountLocks[account] ?? Future<void>.value();
    final result = previous.then((_) => action());
    // Swallow errors from earlier links so a failed op does not poison the
    // chain, but keep the chain order.
    _accountLocks[account] = result.catchError((_) {});
    return result;
  }

  /// Enforces the size limit by removing oldest accessed items (LRU)
  Future<void> _enforceSizeLimit(AccountKey account) async {
    final entries = _cacheEntries[account];
    if (entries == null) return;

    // Calculate total size
    int totalSize = entries.values.fold<int>(0, (sum, entry) => sum + entry.size);

    if (totalSize <= maxSizeBytes) {
      return; // Size limit not exceeded
    }

    // Sort entries by last accessed time (oldest first)
    final sortedEntries = entries.values.toList()
      ..sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

    // Remove oldest entries until size is within limit
    for (final entry in sortedEntries) {
      if (totalSize <= maxSizeBytes) break;

      // Never evict the most recently tracked entry: a file that was just
      // written must stay in the cache even if it alone exceeds the budget
      // (otherwise a single large download would delete itself).
      if (sortedEntries.length > 1 && identical(entry, sortedEntries.last)) {
        break;
      }

      // Delete the file from filesystem
      try {
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
          totalSize -= entry.size;
        }
      } on FileSystemException {
        // Continue even if individual file deletion fails
        continue;
      }

      // Remove from tracking
      entries.remove(entry.filePath);
    }
  }

  /// Updates the access time for a cached file (LRU recency).
  Future<void> touch(AccountKey account, String filePath) async {
    final entries = _cacheEntries[account];
    if (entries != null && entries.containsKey(filePath)) {
      entries[filePath]!.lastAccessed = clock();
    }
  }

  /// Gets current cache size for an account
  Future<int> getCurrentSize(AccountKey account) async {
    final entries = _cacheEntries[account];
    if (entries == null) return 0;

    return entries.values.fold<int>(0, (sum, entry) => sum + entry.size);
  }

  /// Calculates actual directory size (when in-memory tracking isn't reliable)
  Future<int> calculateActualSize(AccountKey account) async {
    final dirPath = await paths.mediaCacheDir(account);
    final dir = Directory(dirPath);

    if (!await dir.exists()) {
      return 0;
    }

    int totalSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          totalSize += stat.size;
        } on FileSystemException {
          // Skip files that can't be accessed
          continue;
        }
      }
    }

    return totalSize;
  }
}