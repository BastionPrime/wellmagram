/// Migration of the legacy single Komet database into per-account files
/// (plan-v3 Т-1.5: «миграция единой БД»).
///
/// Upstream `komet.db` keys every row by account_id; the migration copies
/// each account's rows into its own database file and leaves the legacy file
/// untouched (rollback-safe: legacy stays until the user confirms removal).
library;

import 'dart:developer' as dev;

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'per_account_databases.dart';

/// Tables of the legacy schema whose rows carry `account_id` (upstream
/// app_database.dart: profile, chats_cache, contacts, messages,
/// chat_participants, sync_state, pending_messages, …). The copy keeps the
/// same table shape: rows are moved as-is, only the row filter differs.
class LegacyDbMigrator {
  final PerAccountDatabases databases;
  final LegacyDbSource legacy;
  final List<String> accountTables;

  const LegacyDbMigrator({
    required this.databases,
    required this.legacy,
    this.accountTables = const [
      'chats_cache',
      'contacts',
      'messages',
      'chat_participants',
      'sync_state',
    ],
  });

  /// Migrates one account's rows; returns a per-table row count.
  ///
  /// Damaged rows (the target insert rejects them, e.g. a corrupted or
  /// missing `account_id`) are skipped with a log instead of failing the
  /// whole migration: the remaining rows still land in the per-account
  /// database (ticket OPE-3754).
  Future<Map<String, int>> migrateAccount(AccountKey account) async {
    if (account.network != Network.max) {
      throw UnsupportedError(
        'LegacyDbMigrator: единая БД Komet содержит только MAX-аккаунты '
        '(tg приходит с TDLib в Фазе 2)',
      );
    }
    final migrated = <String, int>{};
    final db = await databases.forAccount(account);
    for (final table in accountTables) {
      final rows = await legacy.rowsFor(table, account.id);
      var inserted = 0;
      for (final row in rows) {
        try {
          await legacy.insertInto(db, table, row);
          inserted++;
        } on Object catch (error, stackTrace) {
          dev.log(
            'LegacyDbMigrator: пропуск повреждённой строки в "$table" '
            '(account ${account.id}): $error',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      migrated[table] = inserted;
    }
    return migrated;
  }

  /// MAX account ids found in the legacy `profile` table.
  Future<List<AccountKey>> legacyAccounts() async {
    final ids = await legacy.profileAccountIds();
    return [
      for (final id in ids) AccountKey(network: Network.max, id: id),
    ]..sort();
  }
}

/// Seam over the legacy single database.
abstract class LegacyDbSource {
  Future<List<int>> profileAccountIds();
  Future<List<Map<String, Object?>>> rowsFor(String table, int accountId);
  Future<void> insertInto(DatabaseLike target, String table, Map<String, Object?> row);
}
