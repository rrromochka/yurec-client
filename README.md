# Cambodgia build of YurecClient

> Дружественный downstream проекта
> [YurecClient](https://github.com/kirbex/yurec-client), развиваемый с
> разрешения оригинального автора. Поддержку этой сборки осуществляют
> сопровождающие Cambodgia, а не автор upstream. Правила синхронизации и
> передачи универсальных исправлений описаны в [UPSTREAM.md](UPSTREAM.md).

Исходный код распространяется по лицензии [MIT](LICENSE).

macOS menu bar приложение — графический фронтенд для [sing-box](https://sing-box.sagernet.org/). Позволяет запускать sing-box в двух режимах (TUN и SOCKS5) одним кликом из строки меню, управлять профилями конфигурации и настраивать маршрутизацию трафика на уровне процессов.

---

## Содержание

- [Требования](#требования)
- [Архитектура](#архитектура)
- [Режим TUN](#режим-tun)
- [Режим SOCKS5](#режим-socks5)
- [Профили](#профили)
- [Подписки](#подписки)
- [Маршрутизация по приложениям (App Routing)](#маршрутизация-по-приложениям-app-routing)
- [Практическая настройка: ChatGPT, Claude, VS Code](#практическая-настройка)
- [Sudoers и права](#sudoers-и-права)
- [Автозапуск и авто-подключение](#автозапуск-и-авто-подключение)
- [Обнаружение внешних процессов](#обнаружение-внешних-процессов)
- [Логи](#логи)
- [Структура проекта](#структура-проекта)

---

## Требования

- macOS 13 Ventura или новее
- [sing-box](https://sing-box.sagernet.org/) **1.11.0 или новее** установлен в системе:
  - `/usr/local/bin/sing-box` (автоопределение)
  - `/opt/homebrew/bin/sing-box` (автоопределение)
  - или любой произвольный путь, заданный в настройках
  - Рекомендуется актуальная стабильная версия (на данный момент 1.13.x)
- Xcode 15+ для сборки

---

## Архитектура

```
YurecClient
├── AppDelegate                  — точка входа, инициализация StatusItem
├── Managers/
│   ├── ProxyManager             — запуск/остановка sing-box, управление жизненным циклом
│   ├── ProfileManager           — хранение и наблюдение за JSON-конфигами, подписки
│   ├── SubscriptionParser       — разбор proxy URI и сборка sing-box конфига
│   ├── ConfigTransformer        — трансформация конфига под режим SOCKS5
│   ├── AppRoutingStore          — хранение списков приложений для маршрутизации
│   ├── AppRoutingEntry          — модель одного приложения в списке маршрутизации
│   ├── ConnectionMode           — enum: .tun / .socks5(port:)
│   ├── SudoersManager           — управление правилом /etc/sudoers.d/yurec
│   └── LaunchAtLoginManager     — управление автозапуском через ServiceManagement
├── Helpers/
│   ├── DNSHelper                — установка/сброс DNS через networksetup
│   └── SystemProxyHelper        — установка/сброс системного SOCKS5-прокси
└── UI/
    ├── StatusMenuController     — меню строки состояния, иконка, анимация
    └── Settings/
        ├── GeneralTabView       — общие настройки, глобальный список App Routing
        └── ProfilesTabView      — управление профилями, настройки на профиль
```

Центральный синглтон — `ProxyManager`. Все остальные компоненты либо вызывают его напрямую, либо подписываются на его `@Published` свойства (`isRunning`, `currentMode`) через Combine.

---

## Режим TUN

### Что происходит

TUN-режим создаёт виртуальный сетевой интерфейс на уровне ядра. Весь исходящий трафик системы перехватывается sing-box на уровне L3 (IP-пакеты), независимо от того, знает ли приложение о прокси или нет. Это полноценный «full VPN» режим — весь трафик идёт через VPN.

### Последовательность запуска

```
StatusMenuController.connectTun()
  └── beginConnect(to: .tun, profile:)
        └── ProxyManager.start(profilePath:, mode: .tun)
              1. killOrphanedSingBox()         — убить осиротевшие процессы sing-box
              2. ConfigTransformer.makeTunConfig() — убирает legacy inbound поля если есть, пишет temp файл
              3. SudoersManager.isInstalled()  — проверить наличие sudoers-правила
                  └── если нет → SudoersManager.install() → диалог пароля (один раз за всё время)
              4. открыть/создать лог-файл      — ~/Library/Logs/YurecClient/sing-box.log
              5. Process() с sudo -n           — sudo -n /path/to/sing-box run -c config.json
              6. isRunning = true              — синхронно, до регистрации terminationHandler
              7. task.terminationHandler       — async на main queue, вызывает handleProcessTermination()
              8. DNSHelper.setDNS("172.19.0.1") — перенаправить DNS всех сетевых интерфейсов
                                                  на fake-ip стек sing-box
```

### DNS в TUN-режиме

После запуска sing-box `DNSHelper.setDNS("172.19.0.1")` выполняет для каждого включённого сетевого сервиса:

```sh
sudo -n /usr/sbin/networksetup -setdnsservers "Wi-Fi" 172.19.0.1
```

`172.19.0.1` — это адрес fake-ip DNS-сервера внутри TUN-интерфейса sing-box. Все DNS-запросы приложений уходят в sing-box, который возвращает фиктивные IP из диапазона `198.18.x.x` и отображает их на реальные домены для последующей маршрутизации.

### Остановка TUN

```
ProxyManager.stop()
  1. SIGKILL всем дочерним sing-box процессам (pgrepSingBox + forceKillPIDs)
  2. killProcess() — terminate() + SIGTERM по PID
  3. DNSHelper.resetDNS() — сбросить DNS обратно на "empty" (DHCP)
  4. cleanupMode() — обнулить состояние
  5. isRunning = false
  6. startLaunchDetectionLoop() — начать следить за внешним запуском sing-box
```

---

## Режим SOCKS5

Режим SOCKS5 работает в двух подрежимах в зависимости от того, заполнен ли список App Routing:

### Подрежим A: чистый SOCKS5 (список приложений пуст)

sing-box запускается без TUN-интерфейса. Открывается **HTTP/SOCKS5-прокси** (`mixed` inbound) на `127.0.0.1:<port>`. YurecClient устанавливает **системный прокси macOS** через `networksetup` — браузеры, Electron-приложения и другие программы, уважающие системные настройки, автоматически начинают ходить через sing-box. Весь трафик через прокси уходит на VPN.

### Подрежим B: гибридный TUN+SOCKS5 (список приложений непустой)

Поднимается и **TUN-интерфейс** (перехватывает весь трафик системы), и **HTTP/SOCKS5-прокси** (`mixed` inbound, для приложений с явной настройкой прокси, например Telegram или CLI-утилиты через `http_proxy`/`https_proxy`). Системный прокси macOS **не выставляется** — TUN уже перехватывает всё.

Маршрутизация по процессам:
- Приложения из списка → **через VPN** (`proxy` outbound)
- Трафик через mixed inbound (Telegram, CLI-утилиты и подобные) → **через VPN** всегда
- Все остальные → **напрямую** (`direct`)

Это позволяет, например, пускать через VPN только Claude, ChatGPT и VS Code, оставляя браузер, почту и остальное работать напрямую.

### Последовательность запуска

```
ProxyManager.start(profilePath:, mode: .socks5(port:))
  1. killOrphanedSingBox()
  2. ensurePortFreeForSocks5(port)     — проверить, что порт свободен
  3. AppRoutingStore.effectiveProcessNames(for: profile)
                                       — получить список process_name (с хелперами)
  4. ConfigTransformer.makeSocks5Config(...)
                                       — трансформировать конфиг (см. ниже)
  5. SudoersManager.isInstalled()
  6. Process() с sudo -n
  7. isRunning = true

  Если список пустой (чистый SOCKS5):
  8a. SystemProxyHelper.enableSOCKS5(port:) — выставить системный прокси macOS

  Если список непустой (гибридный TUN+SOCKS5):
  8b. DNSHelper.setDNS("172.19.0.1")        — как в TUN-режиме
```

### Трансформация конфига (ConfigTransformer)

`ConfigTransformer.makeSocks5Config()` создаёт временный JSON в `/tmp/yurec-socks5-<UUID>.json`:

**Чистый SOCKS5** (список пуст):
1. Убирает `tun`-inbound
2. Убирает существующие `socks`/`mixed`-inbound, добавляет `mixed` на заданном порту
3. Убирает `fakeip` DNS-серверы
4. `route.final` не меняется

**Гибридный TUN+SOCKS5** (список непустой):
1. Оставляет `tun`-inbound как есть
2. Убирает существующие `socks`/`mixed`-inbound, добавляет `mixed` на заданном порту
3. Оставляет `fakeip` DNS (нужен для TUN)
4. Добавляет два правила в начало `route.rules`:
   ```json
   { "inbound": ["mixed-in"], "outbound": "proxy" }
   { "process_name": ["Claude", "Claude Helper (Renderer)", ...], "outbound": "proxy" }
   ```
5. Устанавливает `route.final = "direct"` и `find_process = true`

### Остановка SOCKS5

```
ProxyManager.stop()
  1. SIGKILL всем дочерним sing-box процессам
  2. killProcess()

  Чистый SOCKS5:
  3a. SystemProxyHelper.disableSOCKS5()  — снять системный прокси

  Гибридный TUN+SOCKS5:
  3b. DNSHelper.resetDNS()               — сбросить DNS

  4. cleanupMode() — удалить временный конфиг, обнулить socks5UsesTun
  5. isRunning = false
  6. startLaunchDetectionLoop()
```

---

## Профили

Профили — это JSON-файлы конфигурации sing-box, хранящиеся в `~/.singbox/profiles/`. Приложение наблюдает за этой директорией через **FSEvents** и автоматически обновляет список.

### Способы добавления профиля

| Кнопка | Описание |
|---|---|
| **Add...** | Импортировать готовый JSON-файл sing-box с диска |
| **Add from URL...** | Создать профиль из ссылки на подписку (см. [Подписки](#подписки)) |
| **New Profile...** | Создать пустой профиль-шаблон для ручного редактирования |

### Что хранится в профиле

Стандартный sing-box JSON с:
- `inbounds` — TUN, SOCKS5 и другие входящие
- `outbounds` — proxy, direct, block
- `route.rules` — правила маршрутизации
- `route.final` — дефолтный outbound (обычно `"proxy"`)
- `dns` — DNS-серверы, включая fake-ip для TUN

### Настройки профиля

- **SOCKS5 Port** — порт (по умолчанию 2080)
- **App Routing override** — собственный список приложений вместо глобального
- **Subscription** — URL подписки (отображается, если профиль создан из подписки) + кнопка **Update**

---

## Подписки

Подписка — это URL, по которому отдаётся список прокси-серверов. При добавлении YurecClient скачивает конфигурацию и автоматически превращает её в полноценный sing-box JSON.

### Как добавить

Настройки → Profiles → **Add from URL...**

- **Subscription URL** — ссылка на подписку
- **Profile Name** — имя профиля (подставляется автоматически из hostname URL)

### Обновление

В настройках профиля отображается URL подписки и кнопка **Update** — повторно скачивает и перезаписывает конфиг. Текущие настройки профиля (SOCKS5 порт, App Routing) сохраняются.

### Поддерживаемые форматы ответа

| Формат | Описание |
|---|---|
| Base64 (стандартный и URL-safe) | Строки proxy URI, закодированные в base64 — самый распространённый формат подписок |
| Plain text | Proxy URI по одному на строку |
| sing-box JSON | Готовый конфиг — используется без преобразования |

### Поддерживаемые протоколы

| Протокол | Формат URI |
|---|---|
| VLESS | `vless://uuid@host:port?params#name` — включая XTLS Reality |
| VMess | `vmess://base64(JSON)` |
| Shadowsocks | `ss://base64(method:password)@host:port#name` (SIP002 и legacy) |
| Trojan | `trojan://password@host:port?params#name` |
| Hysteria2 | `hysteria2://password@host:port?params#name` и `hy2://...` |

### Генерируемый конфиг

Из proxy URI собирается полноценный sing-box конфиг, совместимый со всеми режимами работы:

```
inbounds:
  - tun-in  (address: 172.19.0.1/30, auto_route, strict_route, stack: mixed)
  - socks-in (127.0.0.1:2080, заменяется ConfigTransformer при запуске)

dns:
  - remote  → tls://1.1.1.1     (через proxy)
  - local   → 223.5.5.5         (напрямую, для DNS-запросов outbound'ов)
  - fakeip  → 198.18.0.0/15     (для TUN)

outbounds:
  - selector "proxy"  (переключение между серверами если их несколько)
  - <proxy outbounds> (VLESS / VMess / SS / Trojan / Hysteria2)
  - direct / block / dns-out

route:
  - action: sniff (override_destination: true)
  - DNS hijack → dns-out
  - private IP → direct
  - всё остальное → proxy
```

При нескольких серверах в подписке создаётся `selector` outbound — активный сервер можно выбрать через Clash API.

---

## Маршрутизация по приложениям (App Routing)

### Двухуровневая система

```
GlobalEntries (UserDefaults: appRouting.global.v1)
     └── применяется ко всем профилям, у которых overridesGlobal = false

ProfileEntries (UserDefaults: appRouting.profile.entries.<path>)
     └── применяется к профилю, если overridesGlobal = true
```

### Автоопределение хелпер-процессов

macOS-приложения, особенно Electron-based (Claude, VS Code, ChatGPT), запускают множество дочерних процессов с именами, отличными от главного бинаря. Например:

| Приложение | Главный процесс | Процессы, делающие сеть |
|---|---|---|
| Claude.app | `Claude` | `Claude Helper (Renderer)`, `Claude Helper (Plugin)` |
| VS Code | `Code` | `Code Helper (Plugin)` (extension host) |
| ChatGPT | `ChatGPT` | `ChatGPT`, `Updater`, `Downloader` (Sparkle) |

При добавлении `.app`-бандла `AppRoutingEntry` рекурсивно сканирует `Contents/` и автоматически собирает имена всех вложенных `.app`, `.xpc` и `.appex` бандлов. Все они включаются в правило `process_name` в sing-box. Хранить это не нужно — вычисляется динамически из бандла при каждом запуске.

### Поддержка plain-бинарей

Помимо `.app`-бандлов, пикер принимает обычные исполняемые файлы. Это необходимо, например, для нативного бинаря плагина Claude Code в VS Code, который лежит вне бандла VS Code:

```
~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude
```

### Как добавить приложение

В настройках (General или Profiles) нажать `+` → открывается `NSOpenPanel`. Можно выбрать:
- `.app`-бандл из `/Applications` — все хелперы подхватятся автоматически
- Обычный бинарь (например `claude`) через `Cmd+Shift+G` для перехода по пути

---

## Практическая настройка

### Сценарий: Claude desktop, ChatGPT и плагин Claude Code в VS Code ходят через VPN, всё остальное — напрямую

Используется режим **SOCKS5** с непустым списком App Routing (гибридный TUN+SOCKS5).

#### Шаг 1. Добавить Claude.app

Настройки → `+` → `/Applications/Claude.app`

Автоматически будут включены процессы:
- `Claude`
- `Claude Helper`
- `Claude Helper (GPU)`
- `Claude Helper (Plugin)`
- `Claude Helper (Renderer)`

#### Шаг 2. Добавить ChatGPT.app

Настройки → `+` → `/Applications/ChatGPT.app`

Автоматически:
- `ChatGPT`
- `Widgets` (виджет macOS)
- `Updater`, `Downloader`, `Installer` (Sparkle, апдейтер тоже пойдёт через VPN)

#### Шаг 3. Добавить VS Code

Настройки → `+` → `/Applications/Visual Studio Code.app`

Автоматически:
- `Code`
- `Code Helper`
- `Code Helper (GPU)`
- `Code Helper (Plugin)` ← именно здесь работают расширения
- `Code Helper (Renderer)`

> Это покроет трафик самого редактора и встроенных расширений. Но плагин **Claude Code** запускает отдельный нативный бинарь вне бандла VS Code — его нужно добавить отдельно.

#### Шаг 4. Добавить нативный бинарь Claude Code

Настройки → `+` → нажать `Cmd+Shift+G` в открывшейся панели → вставить путь:

```
~/.vscode/extensions
```

Найти папку `anthropic.claude-code-<версия>-darwin-arm64/resources/native-binary/` и выбрать файл `claude`.

Процесс: `claude`

> Путь меняется при обновлении плагина (меняется версия в имени папки). Если плагин перестанет работать через VPN после обновления — повторите этот шаг.

#### Шаг 5. Подключиться в режиме SOCKS5

Клик по иконке в строке меню → выбрать профиль → **SOCKS5**.

После подключения:
- Claude desktop, ChatGPT, VS Code и плагин Claude Code → через VPN
- Браузер, почта и всё остальное → напрямую
- Telegram с настроенным прокси (`127.0.0.1:2080`) → через VPN (через SOCKS5 inbound)

#### Telegram с явным прокси

Если Telegram настроен на использование прокси `127.0.0.1:2080` — он будет работать через VPN автоматически. Добавлять Telegram в список App Routing не нужно: трафик через SOCKS5 inbound всегда идёт на `proxy` outbound согласно первому правилу маршрутизации.

---

## Sudoers и права

И TUN, и SOCKS5 запускаются через `sudo -n` (без пароля). Правило устанавливается **один раз** — при первом подключении показывается стандартный диалог macOS.

### Правило (`/etc/sudoers.d/yurec`)

```
# Managed by YurecClient — do not edit
%admin ALL=(root) NOPASSWD: /usr/local/bin/sing-box, /opt/homebrew/bin/sing-box, /bin/kill, /usr/sbin/networksetup
```

Правило проверяется через `sudo -n -l <path>` перед каждым запуском. Если путь к бинарнику изменился — правило переустанавливается автоматически.

---

## Автозапуск и авто-подключение

| Настройка | Механизм | Хранение |
|---|---|---|
| **Launch at Login** | `SMAppService.mainApp` (ServiceManagement.framework) | системный реестр launchd |
| **Auto-connect on Launch** | проверяется в `AppDelegate.applicationDidFinishLaunching` | `UserDefaults: autoConnectOnLaunch` |

---

## Обнаружение внешних процессов

Если sing-box был запущен не через YurecClient, клиент его всё равно подхватит.

При запуске и после остановки `ProxyManager` запускает `startLaunchDetectionLoop()` — фоновый поток, который каждые 2 секунды ищет процесс `sing-box` через `sysctl(KERN_PROC_ALL)`. При обнаружении:

1. Читает аргументы через `sysctl(KERN_PROCARGS2)` — ищет флаг `run` и путь к конфигу (`-c <path>`)
2. Определяет активный профиль по пути
3. Вызывает `adoptProcess(pid:profilePath:)` — устанавливает `isRunning = true`

Для слежения за усыновлённым процессом используется **kqueue** (`EVFILT_PROC / NOTE_EXIT`). Fallback — polling раз в 2 секунды.

---

## Логи

Лог-файл: `~/Library/Logs/YurecClient/sing-box.log`

Stdout и stderr sing-box перенаправляются в этот файл через `LogForwarder`. Каждый запуск добавляет разделитель:

```
--- YurecClient: starting SOCKS5 (port 2080) @ 2025-01-15 12:00:00 +0000 ---
```

Открыть: меню → **Open Logs**.

### Управление размером

В настройках (General → Logs):

- **Current size** — текущий размер файла
- **Clear Now** — немедленно обнуляет файл (работает и во время активной сессии)
- **Limit log file size** + **Max size** — автоматическое ограничение в МБ. При превышении лимита файл обнуляется и запись продолжается с начала — файл никогда не превышает лимит.

---

## Структура проекта

```
YurecClient/
├── AppDelegate.swift
├── Managers/
│   ├── ConnectionMode.swift         — enum .tun / .socks5(port:), requiresRoot
│   ├── ProxyManager.swift           — ядро: запуск, остановка, process lifecycle
│   ├── ProfileManager.swift         — CRUD профилей, FSEvents, активный профиль, подписки
│   ├── SubscriptionParser.swift     — разбор proxy URI → sing-box JSON конфиг
│   ├── ConfigTransformer.swift      — трансформация конфига для SOCKS5
│   ├── AppRoutingEntry.swift        — модель приложения, авто-сбор хелпер-процессов
│   ├── AppRoutingStore.swift        — двухуровневое хранилище глобал/профиль
│   ├── SudoersManager.swift         — установка /etc/sudoers.d/yurec
│   └── LaunchAtLoginManager.swift   — SMAppService обёртка
├── Helpers/
│   ├── DNSHelper.swift              — networksetup DNS
│   └── SystemProxyHelper.swift      — networksetup SOCKS5 proxy
└── UI/
    ├── StatusMenuController.swift   — NSStatusItem, меню, анимации иконки
    ├── StatusBarIconState.swift     — состояние иконки
    ├── StatusBarIconProvider.swift  — рендер иконки по состоянию
    └── Settings/
        ├── SettingsView.swift           — таб-контейнер
        ├── SettingsWindowController.swift
        ├── GeneralTabView.swift         — Launch at Login, бинарник, App Routing (глобал)
        ├── ProfilesTabView.swift        — список профилей, SOCKS5 порт, App Routing (профиль), подписки
        └── AppRoutingListView.swift     — переиспользуемый список с +/- тулбаром
```
