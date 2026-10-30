import 'package:flutter/material.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/account_registry.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/session_manager.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/telegram/td_ghost.dart';
import 'package:wellmagram/core/storage/spoof_profile.dart';
import 'package:wellmagram/core/storage/spoof_profile_store.dart';

abstract interface class SettingsPrefs {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

class SettingsScreen extends StatefulWidget {
  final AccountRegistry registry;
  final SpoofProfileStore spoofProfiles;
  final SettingsPrefs prefs;
  final SessionMode initialMode;
  final Future<void> Function(SessionMode mode) setMode;
  final Future<TdGhostSettings> Function(AccountKey account) loadGhost;
  final Future<void> Function(AccountKey account, TdGhostSettings settings)
      saveGhost;

  const SettingsScreen({
    super.key,
    required this.registry,
    required this.spoofProfiles,
    required this.prefs,
    required this.setMode,
    required this.loadGhost,
    required this.saveGhost,
    this.initialMode = SessionMode.switchMode,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _sections = [
    'Сети', 'Аккаунты', 'Режимы сессий', 'Ghost', 'Прокси', 'Фиче-флаги'
  ];
  int _selected = 0;
  late SessionMode _mode = widget.initialMode;
  AccountKey? _account;
  Network _network = Network.max;
  TdGhostSettings _ghost = TdGhostSettings.off;
  SpoofProfile? _spoof;
  late final TextEditingController _proxy = TextEditingController(
    text: widget.prefs.getString('proxy_url') ?? '',
  );
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.registry.isLoaded) {
      _account = widget.registry.activeKey ??
          (widget.registry.profiles.isEmpty ? null : widget.registry.profiles.first.key);
      _network = _account?.network ?? Network.max;
      _loadAccountSettings();
    }
  }

  Future<void> _loadAccountSettings() async {
    final key = _account;
    if (key == null) return;
    final ghost = await widget.loadGhost(key);
    final spoof = key.network == Network.max
        ? await widget.spoofProfiles.load(key)
        : null;
    if (mounted) setState(() { _ghost = ghost; _spoof = spoof; });
  }

  Future<void> _setGhost({bool? read, bool? typing, bool? online}) async {
    final key = _account;
    if (key == null) return;
    final next = _ghost.copyWith(
      ghostRead: read, ghostTyping: typing, ghostOnline: online,
    );
    setState(() => _ghost = next);
    await widget.saveGhost(key, next);
  }

  Future<void> _setSpoof(bool enabled) async {
    final key = _account;
    if (key == null) return;
    final profile = (_spoof ?? widget.spoofProfiles.generate()).copyWith(enabled: enabled);
    await widget.spoofProfiles.save(key, profile);
    if (mounted) setState(() => _spoof = profile);
  }

  @override
  void dispose() {
    _proxy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.registry.isLoaded
        ? widget.registry.profiles : const <AccountProfile>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final nav = NavigationRail(
          selectedIndex: _selected,
          onDestinationSelected: (value) => setState(() => _selected = value),
          labelType: wide ? NavigationRailLabelType.all : NavigationRailLabelType.none,
          destinations: [for (final section in _sections)
            NavigationRailDestination(icon: const Icon(Icons.circle_outlined), label: Text(section))],
        );
        return wide
            ? Row(children: [nav, Expanded(child: _content(profiles))])
            : Column(children: [Expanded(child: _content(profiles)),
                SizedBox(height: 80, child: nav)]);
      }),
    );
  }

  Widget _content(List<AccountProfile> profiles) {
    switch (_selected) {
      case 0:
        return ListView(padding: const EdgeInsets.all(24), children: [
          Text('Подключённые сети', style: Theme.of(context).textTheme.headlineSmall),
          for (final network in Network.values)
            RadioListTile<Network>(value: network, groupValue: _network,
              onChanged: (value) => setState(() => _network = value!),
              title: Text(network == Network.max ? 'MAX' : 'Telegram'),
              subtitle: Text('${profiles.where((p) => p.key.network == network).length} аккаунтов')),
        ]);
      case 1:
        return ListView(padding: const EdgeInsets.all(24), children: [
          Text('Аккаунты', style: Theme.of(context).textTheme.headlineSmall),
          if (profiles.isEmpty) const ListTile(title: Text('Аккаунтов пока нет')),
          for (final profile in profiles) RadioListTile<AccountKey>(
            value: profile.key, groupValue: _account, title: Text(profile.displayName.isEmpty ? profile.key.storageId : profile.displayName),
            subtitle: Text(profile.key.network == Network.max ? 'MAX' : 'Telegram'),
            onChanged: (key) async { setState(() { _account = key; _network = key!.network; }); await _loadAccountSettings(); },
          ),
        ]);
      case 2:
        return ListView(padding: const EdgeInsets.all(24), children: [
          Text('Режим сессий', style: Theme.of(context).textTheme.headlineSmall),
          RadioListTile<SessionMode>(value: SessionMode.switchMode, groupValue: _mode, title: const Text('По очереди'), subtitle: const Text('Активна одна сессия'), onChanged: _saving ? null : (v) => _changeMode(v!)),
          RadioListTile<SessionMode>(value: SessionMode.parallel, groupValue: _mode, title: const Text('Параллельно'), subtitle: const Text('Сессии остаются активными'), onChanged: _saving ? null : (v) => _changeMode(v!)),
        ]);
      case 3:
        final key = _account;
        return ListView(padding: const EdgeInsets.all(24), children: [
          Text('Ghost и профиль устройства', style: Theme.of(context).textTheme.headlineSmall),
          if (key == null) const ListTile(title: Text('Выберите аккаунт в разделе «Аккаунты»')) else ...[
            SwitchListTile(value: _ghost.ghostRead, title: const Text('Скрыть прочтение'), onChanged: (v) => _setGhost(read: v)),
            SwitchListTile(value: _ghost.ghostTyping, title: const Text('Скрыть набор текста'), onChanged: (v) => _setGhost(typing: v)),
            SwitchListTile(value: _ghost.ghostOnline, title: const Text('Скрыть статус онлайн'), onChanged: (v) => _setGhost(online: v)),
            if (key.network == Network.max) SwitchListTile(value: _spoof?.enabled ?? false, title: const Text('Подмена профиля устройства'), onChanged: _setSpoof),
          ],
        ]);
      case 4:
        return ListView(padding: const EdgeInsets.all(24), children: [
          Text('Прокси', style: Theme.of(context).textTheme.headlineSmall),
          TextField(controller: _proxy, decoration: const InputDecoration(labelText: 'URL прокси', hintText: 'socks5://host:port'), onSubmitted: (_) => _saveProxy()),
          Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: _saveProxy, child: const Text('Сохранить'))),
        ]);
      default:
        final caps = Capabilities.forNetwork(_account?.network ?? _network);
        final flags = <String, bool>{'ghostMode': caps.ghostMode, 'sendText': caps.sendText, 'sendMedia': caps.sendMedia, 'editText': caps.editText, 'deleteMessages': caps.deleteMessages, 'setReaction': caps.setReaction, 'markRead': caps.markRead, 'setTyping': caps.setTyping, 'downloadMedia': caps.downloadMedia, 'calls': caps.calls, 'pushRegistration': caps.pushRegistration};
        return ListView(padding: const EdgeInsets.all(24), children: [
          Text('Возможности сети (только чтение)', style: Theme.of(context).textTheme.headlineSmall),
          for (final entry in flags.entries) SwitchListTile(value: entry.value, title: Text(entry.key), onChanged: null),
        ]);
    }
  }

  Future<void> _changeMode(SessionMode mode) async {
    setState(() => _saving = true);
    try { await widget.setMode(mode); if (mounted) setState(() => _mode = mode); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  Future<void> _saveProxy() async {
    await widget.prefs.setString('proxy_url', _proxy.text.trim());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Прокси сохранён')));
  }
}
