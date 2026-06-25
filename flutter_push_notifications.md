# Push Notifications — Implementação Flutter

> **Escopo:** Este documento cobre apenas o lado Flutter (Android + iOS).
> A configuração do Firebase Console e a implementação do backend Node.js estão documentados separadamente.
>
> **Referência:** Validado via POC `flutter-poc-notfication`. Usa `firebase_messaging`, `flutter_local_notifications` e `dio`.

---

## Flavors e IDs

| Flavor | Android applicationId | iOS bundle ID | App Name |
|--------|----------------------|---------------|----------|
| `prod` | `io.despex` | `io.despex` | Despex |
| `hml` | `io.despex.hml` | `io.despex.homog` | [HML] Despex |
| `com` | `io.despex.com` | `io.despex.com` | [COM] Despex |

> **Atenção:** O flavor `hml` usa sufixo `.hml` no Android e `.homog` no iOS. Isso não causa problema técnico, mas deve ser lembrado ao registrar os apps no Firebase e ao usar `flutterfire configure`.

---

## 1. Dependências

Adicione ao `pubspec.yaml`:

```yaml
dependencies:
  firebase_core: ^3.13.1
  firebase_messaging: ^15.2.5
  flutter_local_notifications: ^19.2.1
  dio: ^5.x.x          # versão já usada no projeto
  app_settings: ^5.x.x # para redirecionar ao configurações do SO quando permissão negada
```

```bash
flutter pub get
```

---

## 2. Estrutura de arquivos de configuração

### 2.1 Android — `google-services.json`

Cada flavor precisa do arquivo do **projeto Firebase correspondente**. O plugin `google-services` do Gradle resolve automaticamente pelo nome da pasta de source set.

```
android/
  app/
    src/
      main/        ← google-services.json de PROD  (io.despex)
      hml/         ← google-services.json de HML   (io.despex.hml)
      com/         ← google-services.json de COM   (io.despex.com)
```

> Os arquivos são baixados no Firebase Console → seu projeto → ⚙️ Project Settings → aba "General" → seção "Your apps".

### 2.2 iOS — `GoogleService-Info.plist`

Crie as pastas e coloque cada plist no flavor correspondente:

```
ios/
  flavors/
    prod/
      GoogleService-Info.plist   ← projeto despex-prod (io.despex)
    hml/
      GoogleService-Info.plist   ← projeto despex-hml  (io.despex.homog)
    com/
      GoogleService-Info.plist   ← projeto despex-com  (io.despex.com)
```

**Integre a cópia ao script de flavor iOS existente** (`set_flavor_ios.sh` ou `prepare_flavor_ios.sh`) em vez de criar uma nova Build Phase:

```bash
# Adicione ao set_flavor_ios.sh (ou prepare_flavor_ios.sh)
FLAVOR="${FLUTTER_FLAVOR:-prod}"
PLIST_SOURCE="${SRCROOT}/flavors/${FLAVOR}/GoogleService-Info.plist"
PLIST_DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/GoogleService-Info.plist"

if [ -f "$PLIST_SOURCE" ]; then
  cp "$PLIST_SOURCE" "$PLIST_DEST"
  echo "✅ GoogleService-Info.plist copiado para flavor: $FLAVOR"
else
  echo "❌ ERROR: GoogleService-Info.plist não encontrado em $PLIST_SOURCE"
  exit 1
fi
```

> Confirme que o script está ordenado **antes de "Copy Bundle Resources"** no Xcode (Target → Build Phases).

---

## 3. Gerar `firebase_options` por flavor

Execute o comando abaixo uma vez para **cada flavor**, apontando para o projeto Firebase correto:

```bash
# Produção
flutterfire configure \
  --project=despex-prod \
  --android-app-id=io.despex \
  --ios-bundle-id=io.despex \
  --out=lib/firebase/firebase_options_prod.dart

# Homologação — atenção: iOS usa .homog, não .hml
flutterfire configure \
  --project=despex-hml \
  --android-app-id=io.despex.hml \
  --ios-bundle-id=io.despex.homog \
  --out=lib/firebase/firebase_options_hml.dart

# Comercial
flutterfire configure \
  --project=despex-com \
  --android-app-id=io.despex.com \
  --ios-bundle-id=io.despex.com \
  --out=lib/firebase/firebase_options_com.dart
```

> Os nomes dos projetos (`despex-prod`, etc.) são os **Project IDs** visíveis em Firebase Console → Project Settings.

---

## 4. Inicialização do Firebase por flavor

```dart
// lib/firebase/firebase_initializer.dart

import 'package:firebase_core/firebase_core.dart';
import 'firebase_options_prod.dart' as prod;
import 'firebase_options_hml.dart' as hml;
import 'firebase_options_com.dart' as com_flavor;

class FirebaseInitializer {
  static Future<void> init(String flavor) async {
    final options = switch (flavor) {
      'prod' => prod.DefaultFirebaseOptions.currentPlatform,
      'hml'  => hml.DefaultFirebaseOptions.currentPlatform,
      'com'  => com_flavor.DefaultFirebaseOptions.currentPlatform,
      _      => throw Exception('Flavor desconhecido: $flavor'),
    };
    await Firebase.initializeApp(options: options);
  }
}
```

Nos entry points de cada flavor:

```dart
// lib/main_prod.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseInitializer.init('prod');
  runApp(const MyApp());
}

// lib/main_hml.dart — idem com 'hml'
// lib/main_com.dart — idem com 'com'
```

---

## 5. UX de Permissão

**Nunca** chame `requestPermission()` diretamente na inicialização do app. O padrão de mercado é mostrar uma tela de rationale **antes** do dialog do sistema — especialmente crítico no iOS, onde o usuário tem **uma única chance**: se negar, o app nunca mais pode pedir novamente via código.

### 5.1 Quando pedir

Peça permissão em um momento contextualizado, não no primeiro uso:
- Após o login, na tela de configuração de preferências
- Na primeira vez que o usuário realiza uma ação que se beneficia de notificações (ex: faz um pedido)
- Nunca na splash screen ou logo no `main()`

### 5.2 Implementação

```dart
// lib/services/push_notification_service.dart (método público)

/// Verifica status atual e, se necessário, exibe rationale e pede permissão.
/// Retorna true se a permissão foi concedida.
Future<bool> requestPermissionWithRationale(BuildContext context) async {
  // 1. Verifica se já foi concedida — evita mostrar dialog desnecessário
  final current = await _messaging.getNotificationSettings();
  if (current.authorizationStatus == AuthorizationStatus.authorized ||
      current.authorizationStatus == AuthorizationStatus.provisional) {
    return true;
  }

  // 2. Permissão permanentemente negada — só configurações do SO resolve
  if (current.authorizationStatus == AuthorizationStatus.denied) {
    await _handlePermissionPermanentlyDenied(context);
    return false;
  }

  // 3. Mostra sua tela/dialog de rationale antes do popup do sistema
  if (!context.mounted) return false;
  final shouldRequest = await _showPermissionRationale(context);
  if (!shouldRequest) return false;

  // 4. Chama o dialog nativo do SO
  final settings = await _messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  return settings.authorizationStatus == AuthorizationStatus.authorized ||
         settings.authorizationStatus == AuthorizationStatus.provisional;
}

Future<bool> _showPermissionRationale(BuildContext context) async {
  return await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Ativar notificações'),
      content: const Text(
        'Receba atualizações sobre seus pedidos em tempo real '
        'e não perca nenhuma novidade importante.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Agora não'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Ativar'),
        ),
      ],
    ),
  ) ?? false;
}

Future<void> _handlePermissionPermanentlyDenied(BuildContext context) async {
  if (!context.mounted) return;
  final openSettings = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Notificações desativadas'),
      content: const Text(
        'Para receber notificações, ative-as nas configurações do seu dispositivo.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Abrir configurações'),
        ),
      ],
    ),
  );
  if (openSettings == true) {
    await AppSettings.openNotificationSettings();
  }
}
```

---

## 6. PushNotificationService

Crie o serviço em `lib/services/push_notification_service.dart`.

### 6.1 Handler de background (top-level, fora de qualquer classe)

```dart
// DEVE ser top-level function — não pode ser método de classe nem lambda
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase já está inicializado quando este handler é chamado.
  // Use para: atualizar DB local, atualizar badge count.
  // NÃO faça chamadas de UI, Navigator ou BuildContext aqui.
  debugPrint('Background message: ${message.messageId}');
}
```

### 6.2 Classe completa

```dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:app_settings/app_settings.dart';
import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class PushNotificationService {
  final Dio _dio;
  final FirebaseMessaging _messaging;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // Guard contra múltiplas inicializações — evita listeners duplicados
  bool _initialized = false;

  // Mensagem pendente quando app foi aberto pelo tap em notificação
  // enquanto estava fechado. Processada após o router estar pronto.
  RemoteMessage? _pendingNavigationMessage;

  // Streams para integração com gerenciamento de estado (Bloc/Riverpod/Provider)
  final _onMessageController =
      StreamController<RemoteMessage>.broadcast();
  final _onNotificationOpenedController =
      StreamController<RemoteMessage>.broadcast();

  Stream<RemoteMessage> get onMessageReceived => _onMessageController.stream;
  Stream<RemoteMessage> get onNotificationOpened =>
      _onNotificationOpenedController.stream;

  // Construtor principal — usa FirebaseMessaging.instance
  PushNotificationService(this._dio)
      : _messaging = FirebaseMessaging.instance;

  // Construtor para testes — permite injetar dependências mockadas
  PushNotificationService.withDependencies({
    required Dio dio,
    required FirebaseMessaging messaging,
  })  : _dio = dio,
        _messaging = messaging;

  Future<void> initialize() async {
    if (_initialized) return; // previne listeners duplicados
    _initialized = true;

    // 1. Registrar handler de background ANTES de qualquer outra coisa
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // 2. Canal Android (não pede permissão aqui — veja requestPermissionWithRationale)
    await _setupAndroidChannel();

    // 3. Inicializar flutter_local_notifications
    await _initLocalNotifications();

    // 4. Handlers de mensagem
    _setupMessageHandlers();

    // 5. Registrar token no backend
    await _registerToken();

    // 6. Listener de refresh de token
    _messaging.onTokenRefresh.listen(
      (token) => _sendTokenToBackend(token),
    );
  }

  // ── Canal Android ──────────────────────────────────────────────────────────

  Future<void> _setupAndroidChannel() async {
    const channel = AndroidNotificationChannel(
      'high_importance_channel',
      'Notificações Importantes',
      description: 'Canal principal de notificações do app',
      importance: Importance.max,
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  // ── Local Notifications (foreground) ──────────────────────────────────────

  Future<void> _initLocalNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_notification');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false, // permissão já gerenciada via requestPermissionWithRationale
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onLocalNotificationTap,
    );
  }

  // ── Handlers de mensagem ───────────────────────────────────────────────────

  void _setupMessageHandlers() {
    // App em FOREGROUND — FCM não mostra visualmente por padrão
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _showLocalNotification(message);
      _onMessageController.add(message); // notifica Bloc/Riverpod/Provider
    });

    // App em BACKGROUND — usuário tocou na notificação
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _reportNotificationClicked(message);
      _onNotificationOpenedController.add(message);
      _handleDeepLink(message);
    });

    // App estava FECHADO — guarda mensagem para navegação após router estar pronto
    _checkInitialMessage();
  }

  Future<void> _checkInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    if (message != null) {
      _reportNotificationClicked(message);
      _pendingNavigationMessage = message;
      _onNotificationOpenedController.add(message);
    }
  }

  void _showLocalNotification(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;

    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'high_importance_channel',
          'Notificações Importantes',
          icon: '@drawable/ic_notification',
          importance: Importance.max,
          priority: Priority.high,
          color: const Color(0xFFFF9800),
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: message.data['route'],
    );
  }

  void _onLocalNotificationTap(NotificationResponse response) {
    final route = response.payload;
    if (route != null) {
      _navigateTo(route);
    }
  }

  // ── Rastreamento de clique ─────────────────────────────────────────────────

  Future<void> _reportNotificationClicked(RemoteMessage message) async {
    final notificationId = message.data['notification_id'] as String?;
    if (notificationId == null) return;
    try {
      await _dio.post('/api/notifications/$notificationId/clicked');
    } on DioException catch (e) {
      debugPrint('⚠️ Falha ao registrar clique: $e');
    }
  }

  // ── Token ──────────────────────────────────────────────────────────────────

  Future<void> _registerToken() async {
    if (Platform.isIOS) {
      await _getAPNSTokenWithRetry();
    }
    final token = await _messaging.getToken();
    if (token != null) {
      await _sendTokenToBackend(token);
    }
  }

  Future<void> _getAPNSTokenWithRetry({int maxAttempts = 5}) async {
    for (int i = 0; i < maxAttempts; i++) {
      final token = await _messaging.getAPNSToken();
      if (token != null) return;
      await Future.delayed(Duration(seconds: 2 * (i + 1)));
    }
  }

  Future<void> _sendTokenToBackend(String token, {int attempt = 0}) async {
    const maxAttempts = 3;
    try {
      await _dio.post(
        '/api/devices/register',
        data: {
          'fcm_token': token,
          'platform': Platform.isIOS ? 'ios' : 'android',
        },
      );
      debugPrint('✅ FCM token registrado no backend');
    } on DioException catch (e) {
      if (attempt < maxAttempts - 1) {
        // Backoff exponencial: 1s → 2s → 4s
        final delay = Duration(seconds: math.pow(2, attempt).toInt());
        await Future.delayed(delay);
        return _sendTokenToBackend(token, attempt: attempt + 1);
      }
      debugPrint('⚠️ Token registration falhou após $maxAttempts tentativas: $e');
    }
  }

  // ── Logout ─────────────────────────────────────────────────────────────────

  Future<void> deleteToken() async {
    final token = await _messaging.getToken();
    if (token != null) {
      await _dio.delete('/api/devices/unregister', data: {'fcm_token': token});
    }
    await _messaging.deleteToken();
    _initialized = false; // permite reinicializar após novo login
    debugPrint('🗑️ FCM token removido');
  }

  // ── Limpeza de recursos ────────────────────────────────────────────────────

  void dispose() {
    _onMessageController.close();
    _onNotificationOpenedController.close();
  }

  // ── Navegação (ver Seção 7) ────────────────────────────────────────────────

  void _handleDeepLink(RemoteMessage message) {
    final route = message.data['route'] as String?;
    if (route != null) _navigateTo(route);
  }

  void _navigateTo(String route) {
    // Implementação na Seção 7
  }
}
```

### 6.3 Inicialização no app

```dart
// lib/main_prod.dart (e equivalentes para hml/com)

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseInitializer.init('prod');

  final dio = Dio(BaseOptions(baseUrl: 'https://api.despex.io'));
  // configure interceptors de auth aqui

  final pushService = PushNotificationService(dio);
  await pushService.initialize();

  runApp(MyApp(pushService: pushService));
}
```

### 6.4 Logout

```dart
// No seu AuthService ou equivalente
Future<void> logout() async {
  await pushService.deleteToken(); // remove do backend E invalida localmente
  // ... resto do logout
}
```

---

## 7. Deep Link com GoRouter

### 7.1 O problema do app fechado

Quando o app é aberto a partir de uma notificação com o app **fechado**, o router ainda não está montado quando `getInitialMessage()` executa. Chamar `router.go()` nesse momento causa erro. A solução é guardar a mensagem e navegar após o primeiro frame.

### 7.2 Implementação com GoRouter

```dart
// lib/app/router.dart

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final router = GoRouter(
  navigatorKey: _rootNavigatorKey,
  routes: [...],
);
```

```dart
// lib/services/push_notification_service.dart — substitua _navigateTo

// Injete o router no serviço
final GoRouter _router;

PushNotificationService(this._dio, this._router)
    : _messaging = FirebaseMessaging.instance;

void _navigateTo(String route) {
  _router.go(route);
}
```

```dart
// lib/app/app.dart — processe a navegação pendente após o router estar pronto

class MyApp extends StatefulWidget {
  final PushNotificationService pushService;
  const MyApp({required this.pushService, super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Processa notificação pendente após o primeiro frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.pushService.processPendingNavigation();
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(routerConfig: router);
}
```

```dart
// Adicione ao PushNotificationService

/// Deve ser chamado após o router estar montado (addPostFrameCallback).
void processPendingNavigation() {
  if (_pendingNavigationMessage == null) return;
  _handleDeepLink(_pendingNavigationMessage!);
  _pendingNavigationMessage = null;
}
```

### 7.3 Rotas suportadas

Defina as rotas que o backend pode enviar no campo `data.route`:

```
/pedidos/:id          → tela de detalhe do pedido
/chat/:conversationId → tela de chat
/notificacoes         → lista de notificações
/home                 → tela principal
```

> Documente o contrato com o time de backend para que os valores de `route` sejam consistentes.

---

## 8. Mensagens Data-Only (Silent Push)

Além das notificações visíveis, o FCM suporta **mensagens silenciosas** — úteis para sincronizar dados em background sem mostrar nada ao usuário.

### 8.1 Quando usar

| Use caso | Tipo de mensagem |
|----------|-----------------|
| Mostrar notificação visível | `notification + data` |
| Sincronizar dados silenciosamente | `data` apenas (sem `notification`) |
| Atualizar badge count | `data` apenas |
| Pré-carregar conteúdo | `data` apenas |

### 8.2 Como o backend envia

```json
{
  "data": {
    "type": "order_update",
    "order_id": "123",
    "status": "delivered"
  },
  "token": "fcm-token-do-dispositivo"
}
```

> Sem o campo `"notification"` — o sistema não exibe nada visualmente.

### 8.3 Como o Flutter recebe

```dart
// No handler de background (top-level)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.notification == null) {
    // Mensagem silenciosa — seguro para atualizar DB local
    // Ex: atualizar status de pedido no Hive/SQLite
    final type = message.data['type'];
    if (type == 'order_update') {
      await _updateLocalOrderStatus(
        orderId: message.data['order_id']!,
        status: message.data['status']!,
      );
    }
    return;
  }
  // Mensagem com notificação visual — tratada normalmente
}
```

### 8.4 Atenção: iOS exige configuração extra para background

No iOS, mensagens data-only em background só funcionam com `content-available: 1` no payload APNs (o backend deve incluir isso) e com Background Modes habilitado no Xcode (já coberto na Seção 11).

---

## 9. Integração com Riverpod

O `PushNotificationService` expõe dois streams que o Riverpod pode escutar diretamente.

### 9.1 Providers do serviço

```dart
// lib/providers/push_notification_provider.dart

// Provider do serviço — criado uma vez e reutilizado
@riverpod
PushNotificationService pushNotificationService(Ref ref) {
  final dio = ref.watch(dioProvider);
  final router = ref.watch(routerProvider);
  final service = PushNotificationService(dio, router);
  ref.onDispose(service.dispose);
  return service;
}

// Stream de mensagens recebidas em foreground
@riverpod
Stream<RemoteMessage> notificationStream(Ref ref) {
  return ref.watch(pushNotificationServiceProvider).onMessageReceived;
}

// Stream de notificações abertas pelo usuário (tap)
@riverpod
Stream<RemoteMessage> notificationOpenedStream(Ref ref) {
  return ref.watch(pushNotificationServiceProvider).onNotificationOpened;
}
```

### 9.2 Notifier para lista de notificações

```dart
// lib/providers/notification_list_provider.dart

@riverpod
class NotificationList extends _$NotificationList {
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  @override
  List<NotificationItem> build() {
    final service = ref.watch(pushNotificationServiceProvider);

    // Escuta novas mensagens recebidas em foreground
    _messageSub = service.onMessageReceived.listen((message) {
      state = [
        NotificationItem.fromMessage(message, isRead: false),
        ...state,
      ];
    });

    // Quando o usuário abre uma notificação via tap, marca como lida
    _openedSub = service.onNotificationOpened.listen((message) {
      final id = message.data['notification_id'];
      if (id == null) return;
      state = state
          .map((n) => n.notificationId == id ? n.copyWith(isRead: true) : n)
          .toList();
    });

    ref.onDispose(() {
      _messageSub?.cancel();
      _openedSub?.cancel();
    });

    return [];
  }

  void markAsRead(String notificationId) {
    state = state
        .map((n) => n.notificationId == notificationId
            ? n.copyWith(isRead: true)
            : n)
        .toList();
  }
}

// Provider derivado para contagem de não lidas
@riverpod
int unreadNotificationCount(Ref ref) {
  return ref.watch(notificationListProvider).where((n) => !n.isRead).length;
}
```

### 9.3 Consumindo nos widgets

```dart
// Lista de notificações
class NotificationScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationListProvider);
    final unread = ref.watch(unreadNotificationCountProvider);

    return Scaffold(
      appBar: AppBar(title: Text('Notificações ($unread não lidas)')),
      body: ListView.builder(
        itemCount: notifications.length,
        itemBuilder: (_, index) {
          final item = notifications[index];
          return ListTile(
            title: Text(
              item.title,
              style: TextStyle(
                fontWeight: item.isRead ? FontWeight.normal : FontWeight.bold,
              ),
            ),
            onTap: () => ref
                .read(notificationListProvider.notifier)
                .markAsRead(item.notificationId ?? ''),
          );
        },
      ),
    );
  }
}

// Badge no ícone de navegação
class NavBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationCountProvider);
    return Badge(
      isLabelVisible: unread > 0,
      label: Text('$unread'),
      child: const Icon(Icons.notifications),
    );
  }
}

// Snackbar ao receber notificação em foreground
class HomeScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(notificationStreamProvider, (_, next) {
        if (next.hasValue) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(next.value!.notification?.title ?? '')),
          );
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(/* ... */);
}
```

---

## 10. Testes Unitários

Para testar o serviço sem depender do Firebase real, use o construtor `withDependencies`.

### 10.1 Dependências de teste

```yaml
dev_dependencies:
  mockito: ^5.x.x
  build_runner: ^2.x.x
```

### 10.2 Exemplo de teste

```dart
// test/services/push_notification_service_test.dart

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

@GenerateMocks([FirebaseMessaging, Dio])
void main() {
  late MockFirebaseMessaging mockMessaging;
  late MockDio mockDio;
  late PushNotificationService service;

  setUp(() {
    mockMessaging = MockFirebaseMessaging();
    mockDio = MockDio();
    service = PushNotificationService.withDependencies(
      dio: mockDio,
      messaging: mockMessaging,
    );
  });

  test('registra token no backend ao inicializar', () async {
    when(mockMessaging.requestPermission(
      alert: anyNamed('alert'),
      badge: anyNamed('badge'),
      sound: anyNamed('sound'),
    )).thenAnswer((_) async => _fakeSettings(AuthorizationStatus.authorized));

    when(mockMessaging.getToken()).thenAnswer((_) async => 'test-token-abc');
    when(mockMessaging.getInitialMessage()).thenAnswer((_) async => null);
    when(mockDio.post(any, data: anyNamed('data')))
        .thenAnswer((_) async => Response(requestOptions: RequestOptions()));

    await service.initialize();

    verify(mockDio.post(
      '/api/devices/register',
      data: argThat(
        containsPair('fcm_token', 'test-token-abc'),
        named: 'data',
      ),
    )).called(1);
  });

  test('não inicializa duas vezes', () async {
    // configure mocks...
    await service.initialize();
    await service.initialize(); // segunda chamada deve ser ignorada

    verify(mockMessaging.getToken()).called(1); // chamado apenas uma vez
  });
}

NotificationSettings _fakeSettings(AuthorizationStatus status) =>
    const NotificationSettings(
      authorizationStatus: AuthorizationStatus.authorized,
      // ... outros campos com valores padrão
    );
```

---

## 11. Configuração Android

### 11.1 `AndroidManifest.xml`

Dentro de `<manifest>`, adicione a permissão (obrigatório Android 13+):

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

Dentro de `<application>`:

```xml
<!-- Ícone monocromático (branco + transparência) para a barra de status -->
<meta-data
    android:name="com.google.firebase.messaging.default_notification_icon"
    android:resource="@drawable/ic_notification" />

<!-- Cor de fundo do ícone na barra de status -->
<meta-data
    android:name="com.google.firebase.messaging.default_notification_color"
    android:resource="@color/notification_color" />

<!-- Canal padrão para notificações em background/app fechado -->
<meta-data
    android:name="com.google.firebase.messaging.default_notification_channel_id"
    android:value="high_importance_channel" />
```

### 11.2 `res/values/colors.xml`

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="notification_color">#FF9800</color>
</resources>
```

### 11.3 Ícone de notificação

O ícone (`@drawable/ic_notification`) deve ser **monocromático**: apenas branco com fundo transparente. Ícones coloridos são ignorados pelo Android a partir da versão 5.

- Ferramenta para gerar: [Android Asset Studio — Notification Icon](https://romannurik.github.io/AndroidAssetStudio/icons-notification.html)
- Coloque em: `android/app/src/main/res/drawable/ic_notification.png`

---

## 12. Configuração iOS (Xcode)

### 12.1 Capabilities obrigatórias

No Xcode:
1. Target → **Signing & Capabilities** → **"+"** → **Push Notifications**
2. **"+"** → **Background Modes** → marcar **"Remote notifications"**

### 12.2 `Info.plist`

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
    <string>fetch</string>
</array>
```

> **Importante:** O simulador iOS **não recebe** push notifications reais. Sempre teste em dispositivo físico.

---

## 13. Rastreamento de notificações (click tracking)

### Como funciona

O backend inclui um `notification_id` (UUID) no campo `data` de cada notificação enviada. O Flutter detecta o clique e reporta ao backend.

```
Backend envia notificação
    ↓  data: { notification_id: "uuid-abc", route: "/pedidos/123" }

Usuário clica → onMessageOpenedApp ou getInitialMessage dispara
    ↓
Flutter POST /api/notifications/{id}/clicked
    ↓
Backend registra clicked_at no banco
```

### Estados rastreados

| Evento | Como ocorre | Backend notificado? |
|--------|-------------|---------------------|
| Enviado | Backend envia via FCM | Sim (ao enviar) |
| Clicado na barra do sistema | `onMessageOpenedApp` / `getInitialMessage` | Sim |
| Recebido em foreground | `onMessage` | Não (apenas exibe localmente) |
| Descartado (swipe) | Não detectável no Android/iOS | Não |

### Contrato com o backend

```json
{
  "notification": { "title": "...", "body": "..." },
  "data": {
    "notification_id": "uuid-gerado-pelo-backend",
    "route": "/rota/opcional/deep-link",
    "type": "order_update"
  }
}
```

---

## 14. Comportamento por estado do app

| Estado do app | O que acontece | Handler Flutter |
|---------------|---------------|-----------------|
| **Foreground** | FCM não exibe — `flutter_local_notifications` exibe manualmente | `onMessage` |
| **Background** | Sistema exibe automaticamente | `onMessageOpenedApp` (se clicado) |
| **Fechado** | Sistema exibe automaticamente | `getInitialMessage` (se clicado) |

---

## 15. Ciclo de vida do token

```
App instalado / primeiro login
    → _registerToken() → POST /api/devices/register

FCM gera novo token (reinstalação, dados apagados, troca de dispositivo)
    → onTokenRefresh → POST /api/devices/register (upsert no backend)

Logout
    → deleteToken() → DELETE /api/devices/unregister + _messaging.deleteToken()
```

> **Atenção:** Um usuário pode ter múltiplos dispositivos. O backend deve suportar N tokens por usuário e fazer upsert pelo token, não pelo usuário.

---

## 16. Checklist de implementação

### Estrutura e configuração
- [ ] `google-services.json` de prod em `android/app/src/main/`, hml em `src/hml/`, com em `src/com/`
- [ ] `GoogleService-Info.plist` em `ios/flavors/{prod,hml,com}/`
- [ ] Cópia do plist integrada ao script iOS existente, **antes de "Copy Bundle Resources"**
- [ ] `firebase_options_prod.dart`, `firebase_options_hml.dart`, `firebase_options_com.dart` gerados com `flutterfire configure`

### Flutter — Serviço
- [ ] Dependências adicionadas: `firebase_core`, `firebase_messaging`, `flutter_local_notifications`, `dio`, `app_settings`
- [ ] `FirebaseInitializer.init(flavor)` chamado em cada `main_*.dart`
- [ ] `firebaseMessagingBackgroundHandler` declarado como **top-level function**
- [ ] Guard `_initialized` presente em `initialize()`
- [ ] Streams `onMessageReceived` e `onNotificationOpened` conectados ao estado da app
- [ ] `onMessage`, `onMessageOpenedApp`, `getInitialMessage` implementados
- [ ] Token enviado ao backend no primeiro uso e no `onTokenRefresh`
- [ ] Retry com backoff exponencial no registro do token
- [ ] Token deletado e `_initialized = false` no logout

### Flutter — UX e Navegação
- [ ] Permissão pedida via `requestPermissionWithRationale()` em momento contextualizado
- [ ] Fluxo de permissão negada com redirecionamento para configurações do SO
- [ ] `processPendingNavigation()` chamado via `addPostFrameCallback` após o router montar
- [ ] Deep link funcional para todos os valores de `route` definidos com o backend
- [ ] `_onLocalNotificationTap` implementado (tap em foreground)

### Android
- [ ] `POST_NOTIFICATIONS` no `AndroidManifest.xml`
- [ ] `default_notification_icon`, `default_notification_color`, `default_notification_channel_id` no `AndroidManifest.xml`
- [ ] Ícone monocromático em `res/drawable/ic_notification.png`
- [ ] Cor definida em `res/values/colors.xml`

### iOS
- [ ] **Push Notifications** capability adicionada no Xcode
- [ ] **Background Modes → Remote notifications** marcado no Xcode
- [ ] `UIBackgroundModes` no `Info.plist`
- [ ] APNs Key (.p8) configurada no Firebase Console (responsabilidade do time de infra/backend)

### Testes
- [ ] Construtor `PushNotificationService.withDependencies` implementado
- [ ] Teste: token registrado ao inicializar
- [ ] Teste: `initialize()` chamado duas vezes não duplica listeners
- [ ] Dispositivo Android físico (API 33+ para permissão explícita)
- [ ] Dispositivo iOS físico
- [ ] Foreground, background e app fechado
- [ ] Tap na notificação em cada estado
- [ ] Reinstalar o app (testa refresh de token)
- [ ] Logout e novo login (não deve receber antes de logar novamente)
- [ ] Os 3 flavors instalados simultaneamente no mesmo dispositivo

---

*Baseado na POC `flutter-poc-notfication`. Versões: `firebase_core ^3.13.1`, `firebase_messaging ^15.2.5`, `flutter_local_notifications ^19.2.1`. Verifique versões atuais no [pub.dev](https://pub.dev) antes de implementar.*
