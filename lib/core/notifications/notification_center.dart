/// NotificationCenter skeleton (plan-v3 Т-1.10, из Т-3.6 v2).
///
/// Единственная точка формирования уведомлений: BackendEvent (любой
/// бэкенд) → решение показать/сгруппировать → пост через [NotificationPoster]
/// (flutter_local_notifications в продакшне, шов для тестов).
///
/// ВАЖНО (решение владельца п.2.5): источник события НЕ известен и НЕ
/// используется — живое соединение FGS (Т-1.9), FCM или webpush приходят
/// как одинаковые BackendEvent; код, где FCM — единственный путь
/// доставки, блокируется на ревью. Здесь FCM не упоминается вовсе.
///
/// Расширение Т-3.6 добавляет к каркасу:
/// - каналы с приоритетами ([NotificationChannel.priority]) и порядок
///   активных уведомлений для презентера ([activeNotifications]);
/// - группировку по чату (`account:chatId`) — один ключ группы на чат и
///   основа для быстрых действий;
/// - быстрые действия: quick reply с маршрутизацией в бэкенд аккаунта
///   ([quickReplyFor]) и отказ от звонка — только когда сеть умеет звонки
///   ([Capabilities.calls]);
/// - тайминги дедупликации ([dedupWindow]);
/// - служебное уведомление ([notifyService]) — низший канал, без бейджа.
library;

import 'dart:async';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';

/// Channel ids (план: сообщения, звонки MAX, служебный).
enum NotificationChannel {
  messages,
  calls,
  service;

  /// Приоритет канала для презентера: чем больше число, тем важнее.
  /// Входящий звонок важнее сообщения, служебное — самое низкое.
  int get priority => switch (this) {
        NotificationChannel.calls => 2,
        NotificationChannel.messages => 1,
        NotificationChannel.service => 0,
      };
}

/// Быстрые действия, которые презентер может показать на уведомлении.
enum NotificationActionKind {
  /// Быстрый ответ текстом в чат уведомления.
  reply,

  /// Отказ от входящего звонка (сеть должна уметь звонки).
  declineCall,
}

class NotificationAction {
  final NotificationActionKind kind;
  final String label;

  const NotificationAction(this.kind, this.label);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationAction && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);

  @override
  String toString() => 'NotificationAction(${kind.name}: $label)';
}

/// Presentation-independent notification request the poster receives.
class NotificationRequest {
  final NotificationChannel channel;

  /// Group key: account+chat → группировка по чату (план).
  final String groupKey;
  final String title;
  final String body;
  final int id;

  /// Аккаунт-владелец уведомления (и его чат): по нему маршрутизируются
  /// быстрые действия. Известен для каждого запроса, который строит центр.
  final AccountKey? account;

  /// Чат внутри [account], к которому относится уведомление.
  final String? chatId;

  /// Действия, доступные презентеру. Сети, которая действие не умеет,
  /// действие не предлагается вовсе (у сети без звонков отказа нет).
  final List<NotificationAction> actions;

  const NotificationRequest({
    required this.channel,
    required this.groupKey,
    required this.title,
    required this.body,
    required this.id,
    this.account,
    this.chatId,
    this.actions = const [],
  });
}

/// Poster seam: the only place that talks to the platform notification
/// API (flutter_local_notifications in the build image).
abstract class NotificationPoster {
  Future<void> post(NotificationRequest request);
  Future<void> cancelGroup(String groupKey);
  Future<void> setBadge(int count);
}

/// Шов управления звонками для действия «отклонить». Отдельный от
/// [MessengerBackend]: контракт бэкенда (замороженный, план §0.1) операций
/// звонка не содержит; приложение подключает его к живой MAX-сессии.
abstract class CallController {
  Future<void> declineCall(AccountKey account, String chatId);
}

/// Колбэк быстрого ответа: доставляет текст в бэкенд аккаунта уведомления.
typedef QuickReply = Future<SendResult> Function(String text);

/// Каркас: routing BackendEvent → NotificationRequest. Поля события
/// (kind/chatId/text/…) — всё, что используется; никакого поля источника.
class NotificationCenter {
  final NotificationPoster poster;

  /// Разрешение аккаунта в живой бэкенд: через него идут быстрый ответ и
  /// действия звонка. Null — живой сессии для аккаунта нет.
  final MessengerBackend? Function(AccountKey account)? lookupBackend;

  /// Подключённое управление звонками (MAX). Без него отказа в уведомлении
  /// не предлагается.
  final CallController? callController;

  /// Окно дедупликации повторов одного messageId (мс по event.timestamp).
  /// [Duration.zero] (по умолчанию) — окно выключено: идемпотентность
  /// повторной доставки даёт шина событий (контракт центра из OPE-3751).
  /// Реальный путь включает окно при подключении UI-презентера.
  final Duration dedupWindow;

  NotificationCenter({
    required this.poster,
    this.lookupBackend,
    this.callController,
    this.dedupWindow = Duration.zero,
  });

  int _badge = 0;

  final _perChat = <String, int>{};

  /// Последнее уведомление на его id — то, что показывает презентер.
  final _active = <int, NotificationRequest>{};

  /// `groupKey|messageId` → timestamp последнего принятого события.
  final _seenAt = <String, int>{};

  int get badge => _badge;

  int unreadInChat(String groupKey) => _perChat[groupKey] ?? 0;

  /// Focused: активный чат (пользователь смотрит) — уведомления
  /// подавляются, событие только инкрементит счётчик.
  String? focusedChat;

  /// Уведомления, которые сейчас показывает система, в порядке презентера:
  /// сначала более приоритетный канал, внутри канала — стабильный id.
  List<NotificationRequest> get activeNotifications {
    final requests = _active.values.toList();
    requests.sort((a, b) {
      final byPriority = b.channel.priority.compareTo(a.channel.priority);
      return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
    });
    return List.unmodifiable(requests);
  }

  /// Обрабатывает событие любого бэкенда. Возвращает запрос, улетевший в
  /// poster (null — событие не уведомимо, подавлено или дедуплицировано).
  Future<NotificationRequest?> handle(BackendEvent event) {
    switch (event.kind) {
      case BackendEventKind.newMessage:
        return _handleNewMessage(event);
      case BackendEventKind.incomingCall:
        return _handleIncomingCall(event);
      case BackendEventKind.chatRead:
        return _handleChatRead(event);
      case BackendEventKind.messageDeleted:
      case BackendEventKind.messageEdited:
      case BackendEventKind.typing:
      case BackendEventKind.ghostModeChanged:
      case BackendEventKind.connected:
      case BackendEventKind.disconnected:
        return Future.value(null);
    }
  }

  /// Служебное уведомление (низший канал): состояние сессии, сбой доставки,
  /// требование внимания. Бейдж и счётчики чатов не трогает — это не
  /// непрочитанное сообщение.
  Future<NotificationRequest> notifyService({
    required AccountKey account,
    required String title,
    String? body,
  }) async {
    final groupKey = '${account.storageId}:service';
    final request = NotificationRequest(
      channel: NotificationChannel.service,
      groupKey: groupKey,
      title: title,
      body: body ?? '',
      id: _stableId(groupKey),
      account: account,
      actions: actionsForAccount(account, NotificationChannel.service),
    );
    _active[request.id] = request;
    await poster.post(request);
    return request;
  }

  /// Действия канала с учётом возможностей сети владельца: у сети без
  /// звонков действия отказа нет вовсе (не «выключено», а не показано).
  List<NotificationAction> actionsForAccount(
    AccountKey account,
    NotificationChannel channel,
  ) {
    final capabilities = _capabilities(account);
    return switch (channel) {
      NotificationChannel.messages when capabilities.sendText => const [
          NotificationAction(NotificationActionKind.reply, 'Ответить'),
        ],
      NotificationChannel.calls
          when capabilities.calls && callController != null =>
        const [
          NotificationAction(NotificationActionKind.declineCall, 'Отклонить'),
        ],
      _ => const [],
    };
  }

  /// Действия конкретного уведомления (пусто, если аккаунт неизвестен).
  List<NotificationAction> actionsFor(NotificationRequest request) {
    final account = request.account;
    if (account == null) return const [];
    return actionsForAccount(account, request.channel);
  }

  /// Колбэк быстрого ответа в бэкенд аккаунта уведомления; null, если живого
  /// бэкенда для аккаунта нет или сеть не умеет отправку текста. Маршрут
  /// берётся из аккаунта уведомления, а не из текущего активного аккаунта —
  /// ответ уходит в ту сеть, из которой пришло сообщение.
  QuickReply? quickReplyFor(NotificationRequest request) {
    final account = request.account;
    final chatId = request.chatId;
    if (account == null || chatId == null) return null;
    final backend = lookupBackend?.call(account);
    if (backend == null || !backend.capabilities.sendText) return null;
    return (String text) => backend.sendText(chatId, text);
  }

  /// Отказ от входящего звонка. false — канал не звонок, сеть без звонков
  /// (capabilities.calls = false), аккаунт неизвестен или управление
  /// звонками не подключено: действие не показано и ничего не делает.
  Future<bool> declineCall(NotificationRequest request) async {
    if (request.channel != NotificationChannel.calls) return false;
    final account = request.account;
    final chatId = request.chatId;
    if (account == null || chatId == null) return false;
    if (!_capabilities(account).calls) return false;
    final controller = callController;
    if (controller == null) return false;
    await controller.declineCall(account, chatId);
    _active.remove(request.id);
    await poster.cancelGroup(request.groupKey);
    return true;
  }

  Future<NotificationRequest?> _handleNewMessage(BackendEvent event) async {
    final chatId = event.chatId;
    if (chatId == null) return null;
    final groupKey = '${event.account.storageId}:$chatId';
    if (_isDuplicate(groupKey, event)) return null;
    final count = (_perChat[groupKey] ?? 0) + 1;
    _perChat[groupKey] = count;
    _badge++;
    await poster.setBadge(_badge);

    if (focusedChat == groupKey) {
      return null;
    }

    final request = NotificationRequest(
      channel: NotificationChannel.messages,
      groupKey: groupKey,
      title: _chatTitle(event),
      body: count > 1 ? '$count новых сообщений' : (event.text ?? 'Новое сообщение'),
      id: _stableId(groupKey),
      account: event.account,
      chatId: chatId,
      actions: actionsForAccount(event.account, NotificationChannel.messages),
    );
    _active[request.id] = request;
    await poster.post(request);
    return request;
  }

  Future<NotificationRequest?> _handleIncomingCall(BackendEvent event) async {
    final chatId = event.chatId;
    if (chatId == null) return null;
    final groupKey = '${event.account.storageId}:$chatId';
    final request = NotificationRequest(
      channel: NotificationChannel.calls,
      groupKey: groupKey,
      title: 'Входящий звонок',
      body: _chatTitle(event),
      id: _stableId(groupKey) + 1,
      account: event.account,
      chatId: chatId,
      actions: actionsForAccount(event.account, NotificationChannel.calls),
    );
    _active[request.id] = request;
    await poster.post(request);
    return request;
  }

  Future<NotificationRequest?> _handleChatRead(BackendEvent event) async {
    final chatId = event.chatId;
    if (chatId == null) return null;
    final groupKey = '${event.account.storageId}:$chatId';
    final had = _perChat.remove(groupKey) ?? 0;
    _active.removeWhere((_, request) => request.groupKey == groupKey);
    if (had > 0) {
      _badge = _badge - had;
      if (_badge < 0) _badge = 0;
      await poster.setBadge(_badge);
      await poster.cancelGroup(groupKey);
    }
    return null;
  }

  /// Пользователь открыл чат: счётчик и уведомления группы гаснут.
  Future<void> chatOpened(AccountKey account, String chatId) async {
    final groupKey = '${account.storageId}:$chatId';
    final had = _perChat.remove(groupKey) ?? 0;
    _active.removeWhere((_, request) => request.groupKey == groupKey);
    if (had > 0) {
      _badge = _badge - had;
      if (_badge < 0) _badge = 0;
      await poster.setBadge(_badge);
    }
    await poster.cancelGroup(groupKey);
  }

  /// Повтор того же messageId внутри окна [dedupWindow] — не событие: шина
  /// может доставить его дважды, а пользователь видит одно сообщение.
  /// Окно перезапускается от повтора, поэтому поток повторов гасится целиком,
  /// пока они идут чаще окна.
  bool _isDuplicate(String groupKey, BackendEvent event) {
    if (dedupWindow <= Duration.zero) return false;
    final messageId = event.messageId;
    if (messageId == null) return false;
    final cutoff = event.timestamp - dedupWindow.inMilliseconds;
    final stale = _seenAt.entries
        .where((entry) => entry.value < cutoff)
        .map((entry) => entry.key)
        .toList();
    for (final key in stale) {
      _seenAt.remove(key);
    }
    final key = '$groupKey|$messageId';
    final seenAt = _seenAt[key];
    _seenAt[key] = event.timestamp;
    return seenAt != null &&
        event.timestamp - seenAt < dedupWindow.inMilliseconds;
  }

  Capabilities _capabilities(AccountKey account) {
    final backend = lookupBackend?.call(account);
    if (backend != null) return backend.capabilities;
    return Capabilities.forNetwork(account.network);
  }

  String _chatTitle(BackendEvent event) {
    final sender = event.senderId;
    if (sender != null) {
      final numeric = sender.startsWith('u:') ? sender.substring(2) : sender;
      return 'Аккаунт ${numeric.isEmpty ? event.account.storageId : numeric}';
    }
    return 'Чат';
  }

  int _stableId(String groupKey) => groupKey.hashCode & 0x7fffffff;

  Future<void> dispose() async {
    _perChat.clear();
    _active.clear();
    _seenAt.clear();
    _badge = 0;
    await poster.setBadge(0);
  }
}