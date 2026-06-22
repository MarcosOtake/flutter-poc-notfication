# POC Push Notifications — App Flutter

App Flutter para receber push notifications via Firebase Cloud Messaging (FCM).

## Pré-requisitos

- Flutter SDK 3.x+
- Dart 3.x+
- Android Studio ou Xcode (para emulador/device)
- Conta no Firebase

## Configuração do Firebase

### Passo 1 — Criar projeto no Firebase

1. Acesse [console.firebase.google.com](https://console.firebase.google.com)
2. Clique em **"Adicionar projeto"**
3. Dê um nome ao projeto (ex: `poc-push-notifications`)
4. Ative o **Cloud Messaging** nas configurações do projeto

### Passo 2 — Instalar FlutterFire CLI

```bash
dart pub global activate flutterfire_cli
export PATH="$PATH:$HOME/.pub-cache/bin"
```

### Passo 3 — Configurar Firebase no app

Na pasta do projeto Flutter:

```bash
flutterfire configure
```

O CLI irá:
- Pedir para selecionar seu projeto Firebase
- Registrar os apps Android e iOS automaticamente
- Baixar `google-services.json` e `GoogleService-Info.plist`
- Gerar o arquivo `lib/firebase_options.dart` com suas credenciais

### Passo 4 — Configuração Android

Em `android/app/build.gradle`, adicione ao final:

```gradle
apply plugin: 'com.google.gms.google-services'
```

Em `android/build.gradle`, em `buildscript.dependencies`:

```gradle
classpath 'com.google.gms:google-services:4.4.2'
```

### Passo 5 — Configuração iOS

No Xcode (`ios/Runner.xcworkspace`):
1. **Runner → Signing & Capabilities → +**
2. Adicione **Push Notifications**
3. Adicione **Background Modes** → marque:
   - Remote notifications
   - Background fetch

## Instalar e rodar

```bash
flutter pub get
flutter run
```

## O que o app faz

- Solicita permissão de notificação ao usuário
- Exibe o FCM token na tela (com botão de copiar)
- Recebe e exibe notificações em **foreground**
- Trata notificações em **background** (handler separado)
- Detecta quando o app foi aberto via toque na notificação

## Obtendo o FCM Token

Copie o token exibido na tela e use no backend:

```bash
curl -X POST http://localhost:3000/devices \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "meu-device", "token": "SEU_TOKEN_AQUI"}'

curl -X POST http://localhost:3000/notifications \
  -H "Content-Type: application/json" \
  -d '{"deviceId": "meu-device", "title": "Teste", "body": "Funcionou!"}'
```

## Estrutura do projeto

```
lib/
├── main.dart              # Entry point + Firebase init + background handler
├── home_page.dart         # UI: token, permissão, lista de notificações
└── firebase_options.dart  # Gerado pelo flutterfire configure
```
