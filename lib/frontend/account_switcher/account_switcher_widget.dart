// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/account_registry.dart';
import 'package:wellmagram/core/accounts/account_registry_event.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/session_manager.dart';

/// Session state mirroring upstream/core session status requirements.
enum SessionState {
  online,
  degraded,
  banned;

  String get label => name;
}

/// Description of account session info.
class SessionInfo {
  final AccountKey account;
  final SessionState state;
  final bool isActive;

  const SessionInfo({
    required this.account,
    required this.state,
    this.isActive = false,
  });
}

/// Extension on [SessionManager] to support activating an account by [AccountKey].
extension SessionManagerAccountSwitcherExtension on SessionManager {
  Future<void> activate(
    AccountKey key, {
    AccountRegistry? registry,
  }) async {
    if (registry != null) {
      try {
        await registry.setActive(key);
      } on Object catch (_) {
        // Handled quietly if registry is not loaded or key not found
      }
    }
    if (key.network == Network.max) {
      await resume(key);
    } else if (key.network == Network.telegram) {
      // In Phase 3, Telegram session lifecycle is managed by TDLib (T-2.x).
      // Activating Telegram marks the account as active in the registry.
      if (registry != null) {
        try {
          await registry.setActive(key);
        } on Object catch (_) {
          // Handled quietly
        }
      }
    }
  }
}

/// Account switcher UI screen and list component (Phase 3, Т-3.4).
///
/// Features:
/// - Groups accounts by network (MAX and Telegram).
/// - Displays network badge (MAX/TG) and session status (online/degraded/banned).
/// - Highlights currently active account.
/// - Tap invokes activation via [SessionManager] / [onActivate].
/// - Add account button with stub dialog referencing TODO Т-2.2 / Т-1.x.
class AccountSwitcherWidget extends StatefulWidget {
  final AccountRegistry registry;
  final SessionManager? sessionManager;
  final Future<void> Function(AccountKey key)? onActivate;
  final Stream<SessionInfo>? sessionInfoStream;
  final SessionState Function(AccountKey key)? sessionStateResolver;
  final Map<AccountKey, SessionState>? initialSessionStates;
  final void Function(Network network)? onAddAccount;

  const AccountSwitcherWidget({
    super.key,
    required this.registry,
    this.sessionManager,
    this.onActivate,
    this.sessionInfoStream,
    this.sessionStateResolver,
    this.initialSessionStates,
    this.onAddAccount,
  });

  @override
  State<AccountSwitcherWidget> createState() => _AccountSwitcherWidgetState();
}

class _AccountSwitcherWidgetState extends State<AccountSwitcherWidget> {
  late final Map<AccountKey, SessionState> _sessionStates;
  AccountKey? _activeKey;
  StreamSubscription<AccountRegistryEvent>? _registrySub;
  StreamSubscription<AccountKey?>? _sessionManagerSub;
  StreamSubscription<SessionInfo>? _sessionInfoSub;

  @override
  void initState() {
    super.initState();
    _sessionStates = Map<AccountKey, SessionState>.from(
      widget.initialSessionStates ?? const {},
    );
    _activeKey = widget.sessionManager?.activeKey ?? widget.registry.activeKey;

    _registrySub = widget.registry.events.listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.kind == AccountRegistryEventKind.activeChanged) {
          _activeKey = widget.registry.activeKey;
        }
      });
    });

    if (widget.sessionManager != null) {
      _sessionManagerSub = widget.sessionManager!.activeChanges.listen((key) {
        if (!mounted) return;
        setState(() {
          _activeKey = key;
        });
      });
    }

    if (widget.sessionInfoStream != null) {
      _sessionInfoSub = widget.sessionInfoStream!.listen((info) {
        if (!mounted) return;
        setState(() {
          _sessionStates[info.account] = info.state;
          if (info.isActive) {
            _activeKey = info.account;
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _registrySub?.cancel();
    _sessionManagerSub?.cancel();
    _sessionInfoSub?.cancel();
    super.dispose();
  }

  SessionState _resolveState(AccountKey key) {
    if (widget.sessionStateResolver != null) {
      return widget.sessionStateResolver!(key);
    }
    return _sessionStates[key] ?? SessionState.online;
  }

  Future<void> _activateAccount(AccountKey key) async {
    try {
      await widget.registry.setActive(key);
    } on Object catch (_) {
      // Handled quietly if account was not registered in persistent store
    }

    if (widget.sessionManager != null) {
      await widget.sessionManager!.activate(key, registry: widget.registry);
    }

    if (widget.onActivate != null) {
      await widget.onActivate!(key);
    }

    if (mounted) {
      setState(() {
        _activeKey = key;
      });
    }
  }

  void _showAddAccountDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Добавить аккаунт'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Выберите сеть для подключения:'),
              const SizedBox(height: 12),
              ListTile(
                key: const Key('add_account_option_max'),
                leading: _buildNetworkBadge(Network.max),
                title: const Text('MAX'),
                subtitle: const Text('Подключение через токен / kolibri'),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _handleAddAccountAction(context, Network.max);
                },
              ),
              ListTile(
                key: const Key('add_account_option_tg'),
                leading: _buildNetworkBadge(Network.telegram),
                title: const Text('Telegram'),
                subtitle: const Text('Авторизация через TDLib'),
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  _handleAddAccountAction(context, Network.telegram);
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Скелет-заглушка флоу добавления аккаунтов. '
                'TODO: Т-2.2 / Т-1.x (ошибка «вне scope»).',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  void _handleAddAccountAction(BuildContext context, Network network) {
    if (widget.onAddAccount != null) {
      widget.onAddAccount!(network);
    }
    showDialog<void>(
      context: context,
      builder: (noticeContext) {
        final netName = network == Network.max ? 'MAX' : 'Telegram';
        return AlertDialog(
          title: Text('Добавить аккаунт $netName'),
          content: Text(
            'Флоу добавления аккаунта $netName находится в разработке. '
            'TODO: реализация в Т-2.2 / Т-1.x (вне scope).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(noticeContext).pop(),
              child: const Text('Понятно'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNetworkBadge(Network network) {
    final isMax = network == Network.max;
    final text = isMax ? 'MAX' : 'TG';
    final bgColor = isMax ? const Color(0xff2f6f4f) : const Color(0xff0088cc);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildStatusBadge(SessionState state) {
    final Color color;
    final IconData icon;
    switch (state) {
      case SessionState.online:
        color = Colors.green;
        icon = Icons.wifi;
      case SessionState.degraded:
        color = Colors.orange;
        icon = Icons.warning_amber_rounded;
      case SessionState.banned:
        color = Colors.red;
        icon = Icons.block;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(35),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            state.name,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountTile(AccountProfile profile) {
    final isActive = _activeKey == profile.key;
    final state = _resolveState(profile.key);

    return ListTile(
      key: Key('account_${profile.key.storageId}'),
      leading: _buildNetworkBadge(profile.key.network),
      title: Row(
        children: [
          Expanded(
            child: Text(
              profile.displayName.isNotEmpty
                  ? profile.displayName
                  : profile.key.storageId,
              style: TextStyle(
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (isActive)
            const Chip(
              key: Key('active_chip'),
              label: Text('Активен'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
      subtitle: Row(
        children: [
          if (profile.phone.isNotEmpty) ...[
            Text(profile.phone),
            const SizedBox(width: 8),
          ],
          _buildStatusBadge(state),
        ],
      ),
      trailing: Icon(
        isActive ? Icons.check_circle : Icons.circle_outlined,
        color: isActive ? Colors.green : Colors.grey,
        key: Key('status_icon_${profile.key.storageId}'),
      ),
      selected: isActive,
      onTap: () {
        unawaited(_activateAccount(profile.key));
      },
    );
  }

  Widget _buildNetworkGroup({
    required Network network,
    required String title,
    required List<AccountProfile> profiles,
  }) {
    final countLabel = '${profiles.length}';
    return ExpansionTile(
      key: Key('expansion_${network.storageName}'),
      initiallyExpanded: true,
      leading: _buildNetworkBadge(network),
      title: Text('$title ($countLabel)'),
      subtitle: Text(
        profiles.isEmpty ? 'Нет добавленных аккаунтов' : 'Аккаунты сети $title',
      ),
      children: profiles.isEmpty
          ? [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('В этой сети нет аккаунтов'),
              ),
            ]
          : profiles.map(_buildAccountTile).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.registry.profiles;
    final maxProfiles =
        profiles.where((p) => p.key.network == Network.max).toList();
    final tgProfiles =
        profiles.where((p) => p.key.network == Network.telegram).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Переключение аккаунтов'),
        actions: [
          IconButton(
            key: const Key('add_account_appbar_button'),
            icon: const Icon(Icons.person_add),
            tooltip: 'Добавить аккаунт',
            onPressed: () => _showAddAccountDialog(context),
          ),
        ],
      ),
      body: profiles.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Аккаунтов пока нет'),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    key: const Key('add_account_empty_button'),
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить аккаунт'),
                    onPressed: () => _showAddAccountDialog(context),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                _buildNetworkGroup(
                  network: Network.max,
                  title: 'MAX',
                  profiles: maxProfiles,
                ),
                _buildNetworkGroup(
                  network: Network.telegram,
                  title: 'Telegram',
                  profiles: tgProfiles,
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: ElevatedButton.icon(
                    key: const Key('add_account_button'),
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить аккаунт → MAX / Telegram'),
                    onPressed: () => _showAddAccountDialog(context),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
    );
  }
}
