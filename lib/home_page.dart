import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import 'main.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _fcmToken = 'Obtendo token...';
  final List<_NotificationItem> _notifications = [];
  bool _permissionGranted = false;

  int get _unreadCount => _notifications.where((n) => !n.isRead).length;

  @override
  void initState() {
    super.initState();
    _setupFCM();
  }

  Future<void> _setupFCM() async {
    final messaging = FirebaseMessaging.instance;

    // ── 1. Pedir permissão ──────────────────────────────────────────────────
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    setState(() {
      _permissionGranted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
    });

    // ── 2. Obter FCM Token ──────────────────────────────────────────────────
    final token = await messaging.getToken();
    setState(() {
      _fcmToken = token ?? 'Erro ao obter token';
    });
    debugPrint('🔑 FCM Token: $token');

    // ── 2.1 Registrar token no backend ─────────────────────────────────────
    if (token != null) {
      try {
        await http.post(
          Uri.parse('http://192.168.0.161:3000/api/devices/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'fcm_token': token,
            'platform': 'android',
          }),
        );
        debugPrint('✅ Token registrado no backend!');
      } catch (e) {
        debugPrint('⚠️ Falha ao registrar token no backend: $e');
      }
    }

    // ── 3. Listener de foreground — entra como NÃO LIDO ────────────────────
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📱 [FOREGROUND] Mensagem recebida: ${message.messageId}');

      final notification = message.notification;
      if (notification != null) {
        flutterLocalNotificationsPlugin.show(
          notification.hashCode,
          notification.title,
          notification.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'high_importance_channel',
              'High Importance Notifications',
              channelDescription: 'Canal para notificações importantes',
              importance: Importance.max,
              priority: Priority.high,
              icon: '@drawable/ic_notification',
              color: const Color(0xFFFF9800),
            ),
          ),
        );
      }

      setState(() {
        _notifications.insert(
          0,
          _NotificationItem(
            notificationId: message.data['notification_id'] as String?,
            title: message.notification?.title ?? '(sem título)',
            body: message.notification?.body ?? '(sem corpo)',
            time: DateTime.now(),
            state: 'foreground',
            isRead: false, // foreground entra como não lido
          ),
        );
      });
    });

    // ── 4. Tap no sistema (background) — entra como LIDO ──────────────────
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('👆 App aberto via notificação: ${message.messageId}');
      _reportNotificationClicked(message);
      setState(() {
        _notifications.insert(
          0,
          _NotificationItem(
            notificationId: message.data['notification_id'] as String?,
            title: message.notification?.title ?? '(sem título)',
            body: message.notification?.body ?? '(sem corpo)',
            time: DateTime.now(),
            state: 'tap',
            isRead: true, // tap no sistema já conta como lido
          ),
        );
      });
    });

    // ── 4.1 App estava fechado — entra como LIDO ──────────────────────────
    final initialMessage =
        await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      debugPrint(
          '🚀 App iniciado via notificação: ${initialMessage.messageId}');
      _reportNotificationClicked(initialMessage);
      setState(() {
        _notifications.insert(
          0,
          _NotificationItem(
            notificationId:
                initialMessage.data['notification_id'] as String?,
            title: initialMessage.notification?.title ?? '(sem título)',
            body: initialMessage.notification?.body ?? '(sem corpo)',
            time: DateTime.now(),
            state: 'tap',
            isRead: true,
          ),
        );
      });
    }

    // ── 5. Renovação de token ───────────────────────────────────────────────
    messaging.onTokenRefresh.listen((newToken) {
      debugPrint('🔄 Token renovado: $newToken');
      setState(() => _fcmToken = newToken);
    });
  }

  Future<void> _reportNotificationClicked(RemoteMessage message) async {
    final notificationId = message.data['notification_id'] as String?;
    if (notificationId == null) {
      debugPrint('⚠️ Notificação sem notification_id, clique não rastreado.');
      return;
    }
    try {
      final response = await http.post(
        Uri.parse(
            'http://192.168.0.161:3000/api/notifications/$notificationId/clicked'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fcm_token': _fcmToken}),
      );
      debugPrint('✅ Clique registrado (status ${response.statusCode})');
    } catch (e) {
      debugPrint('⚠️ Falha ao registrar clique: $e');
    }
  }

  Future<void> _markAsRead(int index) async {
    final item = _notifications[index];
    if (item.isRead) return;

    setState(() {
      _notifications[index] = item.copyWith(isRead: true);
    });

    if (item.notificationId != null) {
      try {
        final response = await http.post(
          Uri.parse(
              'http://192.168.0.161:3000/api/notifications/${item.notificationId}/clicked'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'fcm_token': _fcmToken}),
        );
        debugPrint(
            '✅ Marcado como lido no backend (status ${response.statusCode})');
      } catch (e) {
        debugPrint('⚠️ Falha ao marcar como lido no backend: $e');
      }
    }
  }

  Future<void> _copyToken() async {
    await Clipboard.setData(ClipboardData(text: _fcmToken));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Token copiado para a área de transferência!'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('POC Push Notifications'),
        centerTitle: true,
        backgroundColor: theme.colorScheme.primaryContainer,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Status de permissão ─────────────────────────────────────────
            Card(
              color: _permissionGranted
                  ? Colors.green.shade50
                  : Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Icon(
                      _permissionGranted
                          ? Icons.check_circle
                          : Icons.cancel,
                      color:
                          _permissionGranted ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _permissionGranted
                          ? 'Permissão de notificação concedida'
                          : 'Permissão de notificação negada',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── FCM Token ───────────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.vpn_key, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'FCM Token',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _fcmToken,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.primary,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _copyToken,
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copiar Token'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Cabeçalho da lista ──────────────────────────────────────────
            Row(
              children: [
                const Icon(Icons.notifications),
                const SizedBox(width: 8),
                Text(
                  'Notificações (${_notifications.length})',
                  style: theme.textTheme.titleMedium,
                ),
                if (_unreadCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$_unreadCount não lida${_unreadCount > 1 ? 's' : ''}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            Expanded(
              child: _notifications.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.notifications_none,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Nenhuma notificação recebida ainda',
                            style: TextStyle(color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _notifications.length,
                      itemBuilder: (context, index) {
                        final item = _notifications[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: item.isRead
                              ? null
                              : Colors.blue.shade50,
                          child: ListTile(
                            onTap: () => _markAsRead(index),
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  backgroundColor: item.state == 'foreground'
                                      ? Colors.blue.shade100
                                      : Colors.purple.shade100,
                                  child: Icon(
                                    item.state == 'foreground'
                                        ? Icons.phone_android
                                        : Icons.touch_app,
                                    size: 18,
                                    color: item.state == 'foreground'
                                        ? Colors.blue
                                        : Colors.purple,
                                  ),
                                ),
                                if (!item.isRead)
                                  Positioned(
                                    top: -2,
                                    right: -2,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: const BoxDecoration(
                                        color: Colors.blue,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Text(
                              item.title,
                              style: TextStyle(
                                fontWeight: item.isRead
                                    ? FontWeight.normal
                                    : FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(item.body),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${item.time.hour.toString().padLeft(2, '0')}:${item.time.minute.toString().padLeft(2, '0')}',
                                  style: theme.textTheme.bodySmall,
                                ),
                                if (!item.isRead)
                                  Text(
                                    'toque p/ ler',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.blue.shade400,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationItem {
  final String? notificationId;
  final String title;
  final String body;
  final DateTime time;
  final String state; // 'foreground' | 'tap'
  final bool isRead;

  _NotificationItem({
    this.notificationId,
    required this.title,
    required this.body,
    required this.time,
    required this.state,
    required this.isRead,
  });

  _NotificationItem copyWith({bool? isRead}) {
    return _NotificationItem(
      notificationId: notificationId,
      title: title,
      body: body,
      time: time,
      state: state,
      isRead: isRead ?? this.isRead,
    );
  }
}
