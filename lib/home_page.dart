import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

    // ── 3. Listener de foreground ───────────────────────────────────────────
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📱 [FOREGROUND] Mensagem recebida: ${message.messageId}');

      final notification = message.notification;
      if (notification != null) {
        // Exibe notificação local quando app está em foreground
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
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
      }

      setState(() {
        _notifications.insert(
          0,
          _NotificationItem(
            title: message.notification?.title ?? '(sem título)',
            body: message.notification?.body ?? '(sem corpo)',
            time: DateTime.now(),
            state: 'foreground',
          ),
        );
      });
    });

    // ── 4. Listener de tap em notificação (background/terminated) ──────────
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('👆 App aberto via notificação: ${message.messageId}');
      setState(() {
        _notifications.insert(
          0,
          _NotificationItem(
            title: message.notification?.title ?? '(sem título)',
            body: message.notification?.body ?? '(sem corpo)',
            time: DateTime.now(),
            state: 'tap',
          ),
        );
      });
    });

    // ── 5. Renovação de token ───────────────────────────────────────────────
    messaging.onTokenRefresh.listen((newToken) {
      debugPrint('🔄 Token renovado: $newToken');
      setState(() => _fcmToken = newToken);
    });
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

            // ── Lista de notificações recebidas ─────────────────────────────
            Row(
              children: [
                const Icon(Icons.notifications),
                const SizedBox(width: 8),
                Text(
                  'Notificações recebidas (${_notifications.length})',
                  style: theme.textTheme.titleMedium,
                ),
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
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  item.state == 'foreground'
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
                            title: Text(item.title),
                            subtitle: Text(item.body),
                            trailing: Text(
                              '${item.time.hour.toString().padLeft(2, '0')}:${item.time.minute.toString().padLeft(2, '0')}',
                              style: theme.textTheme.bodySmall,
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
  final String title;
  final String body;
  final DateTime time;
  final String state; // 'foreground' | 'tap'

  _NotificationItem({
    required this.title,
    required this.body,
    required this.time,
    required this.state,
  });
}
