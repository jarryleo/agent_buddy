# Agent Buddy — Agent Notes

Cross-platform (android / ios / web / linux / macos / windows) Flutter app.
Phone-style UI is enforced everywhere via `lib/widgets/phone_frame.dart`
(centered, fixed-width column on wide screens). On desktop the OS-level
window is also locked to phone width (see "Desktop window size" below).

## Commands

```bash
flutter pub get            # also regenerates l10n via flutter: generate: true
flutter gen-l10n           # only if ARB changes weren't picked up
flutter analyze            # lint (uses flutter_lints, no custom rules)
dart format lib/ test/     # formatting
flutter test               # tests (currently just one smoke test)
flutter test test/widget_test.dart -n "ApiService constructs"   # single test
flutter run -d <device>    # run
flutter build apk          # NOTE: first Android build is very slow (Gradle cold start >5min)
```

No CI, no pre-commit hooks, no `melos`/`fvm` — keep it simple.

## Architecture (one-liner per directory)

- `lib/main.dart` — root + `MultiProvider` (Settings, Api, Tool, Chat, LocalLlm)
- `lib/models/` — plain Dart models with `toJson` / `fromJson` for SharedPreferences (incl. `LocalProvider` for on-device GGUF models). `ChatSession` is the per-conversation model; persisted via a hand-written Hive `TypeAdapter` in `chat_session_adapter.dart`.
- `lib/services/` — `StorageService` (SharedPreferences for settings + `ChatSessionRepository` for chat history), `ApiService` (OpenAI + Anthropic SSE, throws raw `Error:` strings on purpose for the AI), `ToolService` (HTML fetch for `fetch_web`, plus 6 unified personal-data tool dispatchers: `runCalendar` / `runReminders` / `runNotes` / `runTasks` / `runMemory` / `runLocation`, plus `runGoogleSheet` for the desktop-only Google Sheet tool), `LocalLlmService` (wraps `llamadart`'s `LlamaEngine` + `ChatSession` for GGUF, lazy-loaded on first chat, supports mmproj multimodal), `ToolOrchestrator` (multi-round tool-calling loop, transport-agnostic; both `ApiService` and `LocalLlmService` delegate to it so model turns can chain tool calls without manual follow-up bookkeeping), `ChatSessionRepository` (Hive-backed storage for `ChatSession` objects, cross-platform), `MemoryRepository` (Hive-backed storage for AI long-term memories), `DownloadService` (streams URL bytes to `getTemporaryDirectory()/downloads/<id>__<filename>` for the `download` tool, with progress snapshots; the bubble then offers a Save button that opens a system folder picker and copies the file out, dropping the temp file on success), `GoogleSheetsService` (OAuth 2.0 loopback flow + Google Sheets v4 REST API; bundled `assets/json/client_secret.json` is read at runtime so the model can `read` / `update` / `append` / `clear` / `create_tab` / `delete_tab` / `format` the user's spreadsheet — desktop only). `lib/services/platform/` holds the mobile-tool abstractions (`CalendarService` / `RemindersService` / `NotesService` / `TasksService` / `LocationService`) plus per-platform `*_service_io.dart` MethodChannel impls and `*_service_stub.dart` fallbacks for web / desktop. `lib/services/tools/` holds the `ToolBase` abstract class + 13 concrete tool subclasses (`FetchWebTool`, `CurrentTimeTool`, etc.), each defining its own `id`, `name` (简体中文), `description`, platform rules, and `buildSchema()`. Registry at `ToolRegistry` (`tool_registry.dart`) maps `id → ToolBase` — used by `ChatProvider._buildToolsSchema()` and `SettingsProvider.load()` instead of per-tool switch statements.
- `lib/providers/` — `ChangeNotifier`s; `ChatProvider.sendMessage(BuildContext, String)` takes context on purpose to read l10n for user-facing errors
- `lib/pages/` — top-level routes (`HomePage`, `SettingsPage` + 6 tab pages incl. `LocalProvidersTab`, `AddProviderPage`, `AddLocalProviderPage`, `MemoryTab`)
- `lib/widgets/` — reusable (`PhoneFrame`, `ChatInput`, `MessageBubble`, `MarkdownContent`, `CodeBlock`, `ImagePreviewPage`, `NoFocusIconButton`)
- `lib/theme/app_theme.dart` — single light theme, iOS-leaning
- `lib/l10n/` — ARB sources + **generated** `app_localizations*.dart` (checked in, do not hand-edit)

## Repo-specific gotchas

### Desktop window size (`window_manager`)
- `lib/main.dart::_setupDesktopWindow` constrains the OS-level window on Windows / macOS / Linux via the `window_manager` plugin:
  - `maximumSize.width = 480` (phone width; matches `PhoneFrame.maxWidth`).
  - `maximumSize.height` is effectively unbounded (very large value); only width is meaningfully capped.
  - `setMaximizable(false)` — the maximize button is disabled and the OS-level maximize shortcut is blocked.
  - `setResizable(true)` — the user can still drag edges to resize, but only within the [min, max] bounds.
  - Initial size 400×800, minimum 320×568 (smallest reasonable phone).
- On Android / iOS / web the helper returns early (gated by `defaultTargetPlatform`), so the plugin is never invoked on non-desktop. The `window_manager` import itself is web-safe (pure Dart + method channels).
- `WindowOptions` in `window_manager` 0.5.x does **not** expose `maximizable` / `resizable` — they have to be set via the separate `setMaximizable` / `setResizable` calls, fired inside the `waitUntilReadyToShow` callback (right before `show()`) so the FIFO method channel applies them before the window becomes visible.
- First desktop build after adding `window_manager` compiles a small chunk of C++/Obj-C; the build is slower than usual once but not multi-minute (unlike `llamadart`'s native-assets download).

### Localization (l10n)
- `l10n.yaml` has `nullable-getter: false` → `AppLocalizations.of(context)` is non-nullable, never `!` it.
- ARB template is `app_en.arb`; Chinese is `app_zh.arb`. Both must be edited together (English is the source of truth for keys / placeholders).
- Service-layer errors stay in English (e.g. `Error: HTTP 401`) because the AI reads them as tool context. Only wrap with localized prefix in the `ChatProvider` (`l10n.messageErrorPrefix`).

### Streaming
- `ChatProvider` throttles `notifyListeners` to ~80ms during a stream and debounces `SharedPreferences` writes to 300ms — don't tighten without profiling.
- `MessageBubble` wraps markdown in `_StreamingMarkdown` which debounces re-render to 120ms for small deltas, immediate for >64-char deltas. Streaming UX is intentionally snappy over exact-real-time.
- Markdown is re-parsed on every bubble rebuild — keep message sizes sane.

### `flutter_markdown_plus` builder key for code blocks
- The key is `'pre'`, **not** `'code-block'` / `'codeBlock'`. See `lib/widgets/markdown_content.dart` (`_CodeBlockBuilder`).
- Use `element.attributes['class']` (e.g. `language-dart`) to extract the language.
- `markdown` is a direct dep (not just transitive) because the custom builder reaches into `md.Element`.

### `NoFocusIconButton` (desktop keyboard workaround)
- Plain `IconButton` inside an `AppBar` triggers a `HardwareKeyboard` debug assertion on Windows desktop (`A KeyDownEvent is dispatched, but the state shows that the physical key is already pressed`) when modifier keys + Backspace are pressed.
- Always use `NoFocusIconButton` (`lib/widgets/no_focus_icon_button.dart`) for AppBar `leading` / `actions` buttons on pages that also contain a `TextField` / `TabBar`. Don't reintroduce raw `IconButton` there.
- The assertion is debug-only — release builds are unaffected. Upgrading Flutter may eventually make `NoFocusIconButton` unnecessary.

### Tests
- One smoke test exists (`ApiService` constructs) plus service-layer coverage for the new platform tools: `notes_service_test.dart`, `tasks_service_test.dart`, `platform_tools_test.dart` (end-to-end via `ToolService`, incl. memory tool), `platform_calendar_reminders_test.dart` (validation paths + stub-translation), `memory_repository_test.dart` (MemoryRepository: list / multi-keyword search / tag filter / add-with-tags / update / delete / deleteMany / AND-vs-OR semantics), `location_service_test.dart` (LocationServiceIp response parsing, error translation, runLocation envelope, plus the full permission state machine via a fake `LocationService` and MethodChannel mocks for `LocationServiceIo`), `fetch_web_test.dart` (JSON envelope, `link_text` lookup with case-insensitive + whitespace normalization + exact→substring fallback, `include_links` cap at 50, scheme / empty-text / fragment dedup filtering, in-memory per-URL cache, JSON content-type path, truncation), `download_service_test.dart` (DownloadService: success / 4xx → failed / chunked streaming / Content-Disposition filename / URL path fallback / explicit filename / path-separator sanitization / cancel mid-stream / saveTo with non-clashing path suffix / cleanup). Total ~164 tests.
- `StorageService` requires `await init()` first; a bare `new StorageService()` will throw on first read. Don't try to test providers without mocking `SharedPreferences` (`SharedPreferences.setMockInitialValues({})`).
- Hive tests use `Directory.systemTemp.createTemp` + `Hive.init(tempDir.path)` + `setUpAll` to register hand-written adapters. The teardown must close the box and `Hive.deleteBoxFromDisk` between tests.

### Local models (llamadart / GGUF)
- `LocalLlmService` is a thin wrapper around `LlamaEngine` + `ChatSession`. The model is loaded **lazily on the first chat** after the user enables `useLocalModel` and has an active local provider — never at app startup, never on save.
- The model path, mmproj path, context size, temperature, GPU layers and max-tokens are stored in `LocalProvider` (SharedPreferences). The first time the user actually sends a message, `ensureLoaded()` is called and the engine is held in memory for subsequent turns; it's disposed on app teardown.
- **KV-cache reuse across turns of the same session**: the service tracks a `_boundSessionId` (the chat session id). When `streamChat` is called with the same id as the previous turn, the engine's `ChatSession` is **not** reset+seeded — only the new user content is fed in via `session.create(...)`, and llama.cpp's prompt-prefix reuse (`reusePromptPrefix: true`, the default) keeps the KV cache hot. When the id changes (user switches sessions, creates a new one, or deletes the current one), `_boundSessionId` is cleared and the next turn does a full reset+seed.
- Images attached to a chat message are passed through as `LlamaImageContent(path: ...)` pointing at the local file already cached by `ImageService`. Remote URLs / base64 data URLs are not used (the engine prefers file paths on native backends).
- The llmamadart native-assets hook downloads runtime archives on first build per platform — first build after adding the dep is slow (similar to Gradle cold start). Don't be surprised by a multi-minute first compile.

### Tool-calling loop (`ToolOrchestrator`)
- `lib/services/tool_orchestrator.dart` owns the multi-round tool-calling loop. Both `ApiService` (OpenAI / Anthropic) and `LocalLlmService` (llamadart) hand off to it via a `runOneTurn` callback that returns a `TurnResult` (`toolCalls`, `assistantTurn`, `protocolError`, `truncated`).
- The orchestrator enforces `maxToolRounds` (default 6) and surfaces a soft `OrchestratorEvent.error` when the cap is hit, so a runaway model can't burn tokens forever.
- `MessageRole.tool` was added to the role enum; old persisted `ChatMessage` JSON is safe because the deserializer falls back to `user` for unknown values.
- `ChatRequestMessage` gained two protocol-specific fields: `toolCallsWire` (OpenAI) and `anthropicContentBlocks` (Anthropic) so the protocol layer can replay an assistant tool-use turn verbatim in the follow-up payload.
- `ChatProvider.retryToolCall(context, assistantId, toolId)` re-executes a single failed tool call, updates the in-place `ToolCall` card, and (on success) appends a synthetic user message with the new result so the next user turn feeds it back to the model. The button lives in `MessageBubble._ToolCallCard`.

### Download tool (`download`)
- Lets the model pull a file from a URL to the app's temp directory. Hidden on web (`path_provider` has no temp dir there). Model schema: `url` (required) + `filename` (optional; otherwise inferred from URL path or `Content-Disposition`).
- `lib/services/download_service.dart` streams URL bytes into `getTemporaryDirectory()/downloads/<id>__<filename>` and emits a stream of `DownloadItem` snapshots — initial `pending`, throttled `running` frames, then a terminal `completed` / `failed` / `cancelled`. The chat provider pipes each snapshot into `ToolCall.downloads` in place so the bubble's progress bar repaints live; `notifyListeners` is called per frame. Cancelling aborts the HTTP request and drops the partial file.
- `lib/models/download.dart` carries the in-place `DownloadItem` (id, url, filename, bytesReceived, bytesTotal, status, error, localPath, savedPath, contentType). Persisted on `ToolCall` so the bubble survives a restart; after restart, the `localPath` is set but the file may be gone — `DownloadCard` checks `File.exists` and flips to an "expired" hint if so.
- `lib/widgets/download_card.dart` is the bubble UI. Always visible (even when the args/result panel is collapsed) for download tool calls, since the card IS the primary content. Save button opens `FilePicker.platform.getDirectoryPath()`, the chat provider copies the file to the chosen dir with a `(1)` / `(2)` suffix on clash, deletes the temp file, and flips the item to `saved`. Saved state shows a "Reveal" button (macOS / Windows / Linux only — best-effort `open` / `xdg-open` / `explorer`).
- `ChatProvider.saveDownload` / `cancelDownload` / `discardDownload` are the user-affordance methods. The model never sees the local path; the user is the only one who chooses where the file ends up.

### Notification + timer tools (`notification` + `timer`)
- Runtime-only AI-driven push surface. Both tools are auto-seeded on every install (both default to enabled). **Effective only while the app is running** — no scheduling, no background workers, no `zonedSchedule`. If the process dies, all pending timers are lost (the user can always re-create them).
- `lib/services/notification_service.dart` owns the cross-platform `show()` + `setForegroundNotification()` path. Per-platform behaviour:
  - **Android / iOS / macOS / Linux** — real OS-level local notification via `flutter_local_notifications` (channels: `agent_buddy_messages` for one-off, `agent_buddy_timers` for the persistent foreground notification). `flutter_local_notifications` 18.x does not support Windows, so we fall through to the next path.
  - **Windows** — real OS-level modern toast via the `local_notifier` plugin, which wraps the **WinToast** C++/WinRT library (a thin layer over `Windows.UI.Notifications.ToastNotificationManager`). Everything stays in-process — no `powershell.exe` spawn, no EDR / AV alerts. The plugin's `setup()` is called once during `NotificationService.initialize()` with `shortcutPolicy: ShortcutPolicy.requireCreate`, which on first run creates a Start-Menu shortcut with the proper AppUserModelID (a one-time side effect required by the Win10+ modern toast API). The plugin's `notify` / `close` calls are dispatched via the `MethodChannel('local_notifier')` and the Windows path never touches `dart:io` for spawning. One-off chat messages use a per-id `identifier` (`agent-buddy-message-<id>`) so the OS re-uses the toast slot when a caller passes the same `notificationId`; the persistent timer badge uses the fixed `agent-buddy-foreground-timers` identifier so the count updates in-place. Covered by `test/notification_service_local_notifier_test.dart` (mocks the `local_notifier` method channel — no PowerShell, no platform spawn).
  - **Web** — in-app bottom-right toast via `Stream<NotificationToast>` + `NotificationHost` (a `Stack` overlay mounted inside `MaterialApp.builder` in `main.dart`) renders up to 3 stacked toasts that auto-dismiss after 4 s. Also the safety net for any platform where the OS send fails.
- `lib/services/timer_service.dart` is the in-memory queue + `Timer` scheduler. Public API: `create`, `update`, `cancel`, `delete`, `getById`, `tasks`, `pendingCount`, `pruneTerminal`. `onTimerFired` is a callback ChatProvider wires up in its constructor.
- When a task fires: (1) the service calls `_notifications.show(label, prompt)` so the user sees *something* immediately, (2) the in-place task flips to `fired`, (3) `onTimerFired(task)` is called, (4) the foreground notification is refreshed (count decreased by 1, or cleared if zero), (5) a 30 s `pruneTerminal` sweep removes the now-terminal row from the list.
- The timer → AI flow: `ChatProvider._onTimerFired` appends a synthetic user message to the *active* session (`[系统计时触发] <label>` + prompt + action hint) and, if a turn isn't already in flight, calls `continueWithLastUserMessage` to run a fresh streaming turn. The model then sees the reminder and (typically) calls `notification.show(...)` to actually surface a notification, so the user always gets the AI's contextualised message — not a rigid preset.
- Mobile foreground notification: while `pendingCount > 0`, `TimerService` keeps a sticky ongoing notification (Android: `ongoing: true` + `Importance.low`; iOS: best-effort, iOS doesn't pin ongoing). Title carries the count + first pending label. This is the "best-effort keep alive" signal — iOS won't actually keep the process alive; Android can pair this with `flutter_foreground_task` for a true foreground service if needed later.
- Settings UI: `lib/pages/timers_tab.dart` is the 5th tab in `SettingsPage` (length bumped 6 → 7). Shows pending tasks with a live "fires in Xm Ys" countdown that ticks every second; a "show all" switch reveals fired / cancelled history. FAB opens an edit sheet for label / delay / fire-at / prompt / action-hint. Long-press / "..." menu gives edit / cancel / delete. Cancelling a pending task keeps it in the list with `cancelled` status briefly so the user sees the history.
- Schema lives in `lib/services/tools/notification_tool.dart` and `timer_tool.dart`; both are auto-registered in `ToolRegistry` and dispatched through `ToolService.runNotification` / `runTimer`. The model sees the same shape regardless of transport. System prompt guidance: see `ChatProvider._buildSystemPrompts` — there are now soft rules reminding the model that the timer is runtime-only and that the notification is the model-driven step on top of the safety-net fire.

### Sessions & chat persistence
- Chat history is **per-session**, persisted in `hive_ce` via `ChatSessionRepository` (`lib/services/chat_session_repository.dart`). One Hive box holds all sessions; each session stores its full message list, plus `id`, `title`, `createdAt`, `updatedAt`. The on-disk format is hand-written in `lib/models/chat_session_adapter.dart` (no build_runner / code-gen).
- `hive_ce_flutter` is initialized in `main.dart` (`Hive.initFlutter()`); the adapter is registered via `ChatSessionRepository.registerAdapters()` before `StorageService.init()` opens the box.
- One-time migration: the legacy `chat_messages` blob in SharedPreferences is converted into a single "Imported chat" session on first launch. The legacy key is then deleted.
- `ChatProvider` tracks the active session id and exposes `sessions` (newest-first metadata list), `createNewSession()`, `selectSession(id)`, `deleteSession(id)`, `deleteSessions(ids)`. The home page's top-right button opens `SessionManagerSheet` (`lib/widgets/session_manager_sheet.dart`), which lists all sessions and supports single + batch delete.
- All session metadata is loaded eagerly on startup (the metadata is small: just title + timestamps). The full message list for the active session is also loaded eagerly. Other sessions are loaded lazily when selected.
- API path (OpenAI / Anthropic) and local path (llamadart) are both unchanged: each turn still sends the full conversation history over the wire / into the local engine's `ChatSession`. The KV-cache optimization for the local path lives in `LocalLlmService._boundSessionId` (see above); the API path is stateless by protocol design.

### Mobile personal-data tools (`calendar` / `reminders` / `notes` / `tasks`)
Four unified tools that each take an `action` enum and dispatch to the right backend. Lives in `lib/services/platform/` (abstractions + per-platform impls) with thin native bridges under `android/app/src/main/kotlin/cn/leo/agent_buddy/` and `ios/Runner/`.

- `calendar` — system Calendar. iOS: EventKit `EKEvent` (Full Access on iOS 17+). Android: `CalendarContract` events. Permission: Android `READ_CALENDAR` + `WRITE_CALENDAR`; iOS `NSCalendarsFullAccessUsageDescription`.
- `reminders` — iOS: EventKit `EKReminder`. Android: piggy-backs on a user-picked "todo" calendar (all-day events, `CATEGORIES=AGENDA`). The picked calendar id is stored by the native side in a private `SharedPreferences` (`agent_buddy_prefs`) — first call after enabling the tool shows `ReminderCalendarPickerSheet` (`lib/pages/tools_tab.dart`) so the user can choose. If no todo calendar is configured the bridge returns `NO_TODO_CALENDAR`; the Dart side surfaces that as `Error: 请先在设置中选择一个本地日历作为"待办日历"`.
- `notes` / `tasks` — agent-buddy-internal, backed by `hive_ce` boxes (`notes`, `tasks`). No system permission. Open + adapter registration in `main.dart` (adapters in `lib/models/note_adapter.dart` / `task_adapter.dart`). Works on **every** platform including web / desktop. The `tasks` tool is the Android fallback for `reminders` if the user declines the calendar picker.
- All four tools return JSON envelopes (`{action, count, items[]}` for list; `{action, item}` for get/create; `{action, found, item}` for missing; `{action, ok}` for delete). The schema lives in each tool's subclass in `lib/services/tools/` (e.g. `CalendarTool.buildSchema()`); the dispatcher is `ToolService.runCalendar` / `runReminders` / `runNotes` / `runTasks`. Errors from native bridges (permission denied, no todo calendar, OS not supported) are translated to `ToolException` so the model can react.
- On non-mobile platforms the `*_service_io.dart` factory (`calendar_service_factory.dart` / `reminders_service_factory.dart`) returns a `*_service_stub.dart` that throws `UnsupportedError` → caught and rethrown as `ToolException('... not supported on this platform')`. The schema is gated on `CalendarTool.isSupportedOnCurrentPlatform` / `RemindersTool.isSupportedOnCurrentPlatform` so the model never even sees `calendar` / `reminders` on web / desktop.

### Location tool (`location`)
Coarse "where am I" lookup so the AI can answer weather / timezone / "near me" questions. Single action `get`. Always available — `LocationTool.isSupportedOnCurrentPlatform == true` on every platform.

- **Mobile path** — `LocationServiceIo` talks to a `MethodChannel('agent_buddy/location')` backed by `LocationBridge.kt` (Android, FusedLocationProviderClient + Geocoder) and `LocationBridge.swift` (iOS, `CLLocationManager.requestLocation`). Both methods (`ensurePermission` AND `getCurrentLocation`) drive the system prompt on the first call: if authorization is `.notDetermined` / not yet asked, the native side calls `requestWhenInUseAuthorization()` / `requestPermissions(FINE, COARSE)` itself, parks the pending result, and resumes via `didChangeAuthorization` / `onRequestPermissionsResult` once the user answers. iOS does not include reverse-geocoding (would need CLGeocoder + network round-trip) — `city / region / country` come back as `null` and the model reads the timezone from `TimeZone.current.identifier` instead. Both bridges honour a `timeoutMs` parameter. Permanent denial (the user picked "Don't Allow" twice on iOS, or "Don't ask again" on Android) is detected via the `agent_buddy_prefs/location_permission_requested` flag on Android and via `authorizationStatus == .denied` on iOS — surfaced as `PlatformPermissionStatus.permanentlyDenied` → `ToolException('... permanently denied; open system settings ...')`.
- **Desktop / web path** — `LocationServiceIp` (used by the factory when the platform is not Android / iOS) hits `ip-api.com/json/?lang=zh-CN`, a free, no-key endpoint that maps the user's public IP to lat / lon + city + region + country + timezone + ISP. Accuracy is city-level, which is enough for "what's the weather here" / "what's my timezone" use cases. No OS prompt needed.
- **Schema** lives in `LocationTool.buildSchema()` (`lib/services/tools/location_tool.dart`). The model's view: `action=get` (optional `timeout_ms`, default 10000). Returns `{action, location: {latitude, longitude, accuracyMeters?, city?, region?, country?, countryCode?, timezone?, isp?, source: gps|ip, fetchedAtMs}}`.
- **AI guidance** — soft rule in `ChatProvider._buildSystemPrompt()`: "only call when the user asks about weather, nearby, local timezone, etc. — never volunteer."
- **Permissions** — Android adds `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` to `AndroidManifest.xml`; iOS adds `NSLocationWhenInUseUsageDescription` to `Info.plist`. The Android build also pulls `com.google.android.gms:play-services-location:21.3.0` into `android/app/build.gradle.kts` (first Gradle build after this commit is the usual >5min cold start).
- **Testability** — `ToolService` constructor takes an optional `locationBuilder: LocationServiceBuilder` so tests can inject a `LocationServiceIp` with a stubbed `http.Client` and assert the IP path's JSON envelope, error translation, and action validation without hitting the network.

### Mobile file tool (SAF + sandbox)

The `file` tool now works on Android / iOS in addition to desktop. Desktop behavior is **unchanged** — the same `dart:io` code path runs against the user's working directory or any absolute path.

On mobile the model is gated to two opaque path schemes so it can never reach the raw filesystem:

- `app://documents/...` / `app://temp/...` / `app://support/...` — the app's own sandbox (`getApplicationDocumentsDirectory` / `getTemporaryDirectory` / `getApplicationSupportDirectory`). Resolved in Dart via `path_provider`; `..` segments are rejected by `p.normalize` + a `startsWith` check so a model can't escape the sandbox.
- `picker://<id>` — a file the user picked via the system picker. The id is minted by the native bridge (`f-<seq>`); the underlying `content://` (Android) or security-scoped `file://` (iOS) URI never leaves the bridge.

**Mobile-only actions** (in `lib/services/tools/file_tool.dart` → `_mobileSchema`):

- `pick({mime_type?, read_only?})` — opens the system file picker. **Blocks the Dart-side Future until the user picks or cancels.** Mirrors the `LocationBridge` / `CalendarBridge` permission-park pattern: the call is parked in the native bridge, the OS handles the UI, the result comes back on the same channel. The model never sees a transient "no permission" error before the user has had a chance to answer.
- `release(id)` — drops the in-memory `id → URI` mapping. On Android the bridge also calls `releasePersistableUriPermission`; on iOS it calls `stopAccessingSecurityScopedResource`. Idempotent.
- `read_attr` / `read` / `write` / `append` work against both schemes.
- `delete` / `rename` / `list_dir` work **only against `app://`**. Picker paths are rejected with a friendly `release` hint because the OS picker grants per-URI access for read/write, not arbitrary delete on the user's filesystem.

**Android permission semantics** — for scope (a) **no Android runtime permission is required**. `Intent.ACTION_OPEN_DOCUMENT` (`SAF` picker) grants per-URI access via `Intent.FLAG_GRANT_READ_URI_PERMISSION` (and `_WRITE_` when not read-only) the moment the user picks a file. This works the same on API 19+; we never need `READ_EXTERNAL_STORAGE`, `READ_MEDIA_*` (API 33+), or `MANAGE_EXTERNAL_STORAGE` (API 30+) for the picker. Persistable URI permission is **not** taken automatically — the model is expected to `release` the id when done, and the OS grant expires on its own schedule. The bridge implements `ensurePermission` as a deliberate `NOT_SUPPORTED` error so any probe gets a clear answer (there is nothing to check outside of `pick`).

**iOS permission semantics** — same story: `UIDocumentPickerViewController` handles its own authorization. No Info.plist usage description is required; the system copies the picked file into the app's inbox-style temp dir and the bridge holds the URL with `startAccessingSecurityScopedResource()` until `release`.

**"Wait for user action" UX** — `ToolCall.awaitingUserAction` (defaults to `false`, persisted to JSON) is set to `true` by `ChatProvider._isAwaitingUserAction` when the tool is `file` and the action is `pick`. The message bubble renders a "等待用户在系统选择器中操作…" hint under the running card (see `MessageBubble._ToolCallCard`). The flag is cleared on the `toolDone` event in both success and failure paths. A user cancel is **not** a failure: the tool returns `{ok:false, cancelled:true}` so the model can pivot (e.g. write to the sandbox) without the chat provider seeing an exception.

**Concurrency** — at most one picker visible at a time. Multiple `pick` calls while a picker is up are queued in the native bridge and resumed in order, mirroring `LocationBridge` / `CalendarBridge`.

**Files added / changed** for this feature:
- Dart: `lib/services/platform/file_service.dart` (abstract + path helpers), `file_service_impl.dart` (production: `path_provider` + MethodChannel picker backend), `file_service_stub.dart` (web fallback), `file_service_factory.dart`; `lib/models/picked_file.dart`; `lib/services/tools/file_tool.dart` (split into `_executeMobile` / `_executeDesktop`); `lib/services/tool_service.dart` (`fileBuilder` constructor param + `runFile` delegate); `lib/services/tools/tool_base.dart` (`overridePlatform` / `resetPlatformOverrides` for the test host); `lib/models/message.dart` (`ToolCall.awaitingUserAction`); `lib/widgets/message_bubble.dart` (awaiting hint); `lib/l10n/app_*.arb` (new `toolCallAwaitingUser` key, updated `toolDescFile`).
- Android: `android/app/src/main/kotlin/cn/leo/agent_buddy/FileBridge.kt` (SAF picker, `pendingPicks` FIFO, per-URI read/write with cap, `releasePersistableUriPermission` on release); `MainActivity.kt` (registers the bridge, forwards `onActivityResult` to it).
- iOS: `ios/Runner/FileBridge.swift` (`UIDocumentPickerViewController` with security-scoped URL lifecycle, FIFO queue); `AppDelegate.swift` (registers the bridge).
- Tests: `test/file_service_test.dart`, extended `test/file_tool_working_dir_test.dart`.

### Memory system (`memory` tool + Memory tab)
Cross-session long-term memory for the AI. Backed by a `hive_ce` box (`memories`), persisted via `MemoryRepository` (`lib/services/memory_repository.dart`) and surfaced to the user in Settings → Memory.

- **Data model** (`lib/models/memory.dart` + `memory_adapter.dart`): `Memory { id, content, source, createdAt, tags: List<String> }` with a hand-written `TypeAdapter<Memory>` (typeId = 4, version = 2). `source` is `'ai'` (written by the model) or `'user'` (added by the user in Settings). `tags` is a free-form list of keywords the model attaches to a memory at write time to make future fuzzy searches cheaper. The v1 wire layout (pre-tags, written by the previous app version) is still readable: `MemoryAdapter.read` detects `version=1` and returns a `Memory` with `tags=[]`. `id` format: `m_<µs>_<boxLength>`, mirrors `Note` / `Task` conventions.
- **Repository** (`MemoryRepository`): `list({String? keyword, List<String>? keywords, List<String>? tags, int max = 50})` returns memories **sorted newest-first** by `createdAt`. Filtering uses **OR semantics** for high recall:
  - `keyword` (legacy single-string): case-insensitive `contains` on `content`.
  - `keywords` (preferred multi-keyword search): a memory matches if **any** keyword is contained in its `content` OR `tags`.
  - `tags`: a memory matches if **any** of its tags intersects the filter.
  - When both `keyword` and `keywords` are passed, `keywords` wins.
  Plus `get / add / update / delete / deleteMany / length / open / close / registerAdapters`. `add` / `update` accept an optional `tags` list (whitespace-trimmed, de-duplicated, case-folded for matching).
- **Tool** (`memory`) — 7 actions dispatched by `ToolService.runMemory`:
  - `list` — optional `max` (default 20)
  - `search` — preferred `keywords: string[]` (multi-keyword OR on content + tags) or legacy `keyword: string`; optional `tags: string[]` for narrowing; `max` default 20. At least one of `keywords` / `keyword` / `tags` must be non-empty.
  - `get` — required `id`
  - `create` — required `content`; optional `tags: string[]` (3~6 keywords recommended for recall); source is hard-coded to `'ai'`
  - `update` — required `id`; optional `content` and/or `tags`; missing `tags` keeps the existing list
  - `delete` — required `id`
  - `delete_batch` — required non-empty `ids: string[]`
  - All errors throw `ToolException` (envelope shape is consistent with the other personal-data tools).
- **Schema** lives in `ChatProvider._buildToolsSchema()` via `ToolRegistry.byId('memory')`. Available on every platform (`BuiltinTool.memory.isSupportedOnCurrentPlatform == true`); auto-seeded by `SettingsProvider.load()`'s builtin loop, so existing users get it enabled on first launch after upgrade.
- **AI guidance** — the system prompt (`ChatProvider._buildSystemPrompt()`, last block) tells the model to (a) attach a rich `tags: string[]` to every `create` / `update` so future `search` calls are cheap, and (b) prefer `keywords: string[]` (multiple related terms) over a single `keyword` when searching. The model still has full judgment — these are soft rules.
- **Settings UI** — `lib/pages/memory_tab.dart` is the 6th tab in `SettingsPage` (length bumped 5 → 6). Features: keyword search box, multi-select batch delete (long-press to enter, like `SessionManagerSheet`), inline "..." menu for per-row edit / delete, FAB for adding a new memory. `MemoryProvider` (`lib/providers/memory_provider.dart`) is a `ChangeNotifier` wrapper around the repo and is the only thing the UI talks to.
- **No notification on user edits** — when the user adds / edits / deletes a memory from Settings, the AI is *not* notified. The change is visible to the model only on the next turn that calls `memory` (search / list).

### Google Sheet tool (`google_sheet`)
Lets the model read / write the user's own Google Sheet. OAuth 2.0 loopback flow + Google Sheets v4 REST API. Desktop-only (Windows / macOS / Linux); hidden on Android / iOS / Web because the bundled `client_secret.json` is a Google *Desktop app* credential whose only `redirect_uri` is `http://127.0.0.1`.

- **OAuth + service** — `lib/services/google_sheets_service.dart`. Extends `ChangeNotifier` so the settings UI can react to auth-state transitions (`unconfigured` / `unauthorized` / `authorizing` / `authorized` / `error`). Credentials are read once from `assets/json/client_secret.json` (the only out-of-the-box difference from the Google sign-in library: the asset ships a `client_secret` and the loopback scheme). Token persistence (access + refresh + expiry + authed email) is in `lib/models/google_sheet_config.dart` under SharedPreferences key `google_sheet_config`.
  - **Flow** — `startAuthorization()` binds an `HttpServer` on `127.0.0.1` with an ephemeral port, builds the Google auth URL with `redirect_uri=http://127.0.0.1:<port>&state=<csrf>&access_type=offline&prompt=consent`, opens it via `url_launcher` (`LaunchMode.externalApplication`), waits up to 90s for the callback (state-checked, error-aware, HTML "you can close this tab" response), then exchanges the code for tokens at `token_uri`. Refresh tokens are used automatically when the access token is within 5 min of expiry (`GoogleSheetConfig.needsTokenRefresh`); concurrent refresh requests share a single in-flight `Future` via `_refreshInFlight` to avoid a thundering herd.
  - **Scopes** — `https://www.googleapis.com/auth/spreadsheets` + `https://www.googleapis.com/auth/userinfo.email` (used to populate the `authedEmail` field in the settings UI).
  - **Methods** — `listTabs({spreadsheetId})`, `readRange(range, {spreadsheetId, tab})`, `updateRange(range, values, {spreadsheetId, tab})`, `appendRows(range, values, {spreadsheetId, tab})`, `clearRange(range, {spreadsheetId, tab})`, `batchUpdate(body, {spreadsheetId})`, `fetchSheetProperties(bearer, {spreadsheetId})`, `updateSelection({spreadsheetId, defaultTab})`, `signOut()`. All public methods honor an optional `spreadsheetId` override (handy for batch operations against multiple sheets in the future).
  - **Range resolution** — `_qualifyRange(range, tab)` auto-prepends the configured `defaultTab` when the A1 range has no `!` prefix; names with spaces / hyphens / quotes are wrapped in single quotes per Sheets A1 grammar.
  - **Error translation** — `401` flips state to `error` with message `"Google 授权已过期,请重新测试连接"`; other 4xx/5xx throw `StateError` with the body snippet (truncated to 400 chars).
- **Tool** (`lib/services/tools/google_sheet_tool.dart`) — `ToolBase` subclass, 8 actions dispatched by `ToolService.runGoogleSheet`:
  - `list_tabs` — no args besides the implicit spreadsheet. Returns `{action, spreadsheet_id, default_tab, count, tabs: string[]}`.
  - `read` — `range` (A1); optional `tab` to override the default. Returns `{action, range, rows, cols, values: 2D array}`.
  - `update` — `range`, `values: 2D array`; cells outside the target range are untouched. Uses `valueInputOption=USER_ENTERED` so `=A1+1` style strings become formulas, dates parse, etc. Returns `{action, updated_range, updated_rows, updated_columns, updated_cells}`.
  - `append` — `range` (just identifies the tab; actual rows go to the end), `values`. Uses `valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS`.
  - `clear` — `range`. Calls `values/{range}:clear`; formatting is preserved unless the caller also issues a `format` request.
  - `create_tab` — `title`. Adds a tab via `batchUpdate: addSheet`.
  - `delete_tab` — `tab` (or default). Resolves the title to a `sheetId` via `fetchSheetProperties` first (so the user can refer to tabs by name), then issues `batchUpdate: deleteSheet`.
  - `format` — `range`, `tab?`, plus any of `bold / italic / strikethrough / underline / font_size / text_color / background_color / number_format_type / number_format_pattern`. Builds a `batchUpdate: repeatCell` request with the right `fields=` mask; the mask is auto-generated from which attributes the model actually passed so the Sheets API doesn't blow away unrelated formatting.
  - All cell colors accept `#RRGGBB` or `#RRGGBBAA`; `number_format_type` is one of `NUMBER / PERCENT / CURRENCY / DATE / TIME / DATE_TIME / SCIENTIFIC / TEXT`.
  - The spreadsheet id is **implicit** (from the config) — the model never passes it. This is the single biggest token saver for the tool.
- **Platform gate** — `isSupportedOnCurrentPlatform => isDesktop()` and `buildSchema()` returns `{}` on mobile / web, so the model never sees the tool. Matches the existing `run_command` / `file` / `get_environment` pattern.
- **Setup flow** — `BuiltinTool.googleSheet.isEnabledByDefault = false` (the only other default-off tool is `reminders`; the two are listed together in the test exception list at `test/reminders_tool_defaults_test.dart:32` and `test/settings_provider_reminders_test.dart`). The settings tab row is tappable (`onTap` in `_ToolCard`, see `lib/pages/tools_tab.dart`); tapping it always opens `GoogleSheetSettingsSheet`. If the user flips the switch on while the config is unconfigured (`!GoogleSheetConfig.isFullyConfigured`), the tab jumps to the settings sheet and rolls the switch back to off — only after the user successfully saves a valid config does the next flip actually enable the tool.
- **Settings sheet** — `lib/pages/google_sheet_settings_sheet.dart`. Spreadsheet URL/ID input (auto-extracts the bare ID from the canonical `/d/<id>/edit` URL via regex), "测试连接" button (launches the OAuth flow), auth-state badge (5 visual states, with the `stateError` message surfaced inline), default-tab dropdown (populated from `listTabs`, refreshable), "退出登录" affordance. Save / Cancel buttons mirror `ReminderCalendarPickerSheet` styling.
- **AI guidance** — the system prompt (`ChatProvider._buildSystemPrompt()`) has a one-line bullet pointing the model at `list_tabs` first, then `read`/`update`/`append`/`clear` with A1 ranges, then `create_tab`/`delete_tab` for whole-tab ops, then `format` for attributes. The full schema is in `GoogleSheetTool.buildSchema()` with action-enum + property descriptions the model can introspect.
- **State propagation** — `main.dart` constructs a single `GoogleSheetsService` and registers it both as a `ChangeNotifierProvider` (so the settings sheet can `context.watch` it) and as the `googleSheets` field of `ToolService` (so the `google_sheet` tool sees the same instance). Hydration happens via `svc.load()` at startup, which calls `StorageService.loadGoogleSheetConfig()`.
- **Tests** — `test/google_sheet_tool_test.dart` (16 tests, all envelopes + validation) and `test/google_sheets_service_test.dart` (18 tests, mock-http Sheets API + token refresh + state machine + concurrent-refresh de-dup). 35 new tests added; the existing `reminders_tool_defaults_test` + `settings_provider_reminders_test` were updated to add `google_sheet` to the "default-off" exception set.

## Scope / what "done" looks like

`README.md` ends with a `代办事项` (TODO) list — treat that as the current feature backlog, not docs. v1 is shipped (chat + settings + provider + role + tools + skill, i18n, markdown rendering, code highlighting, image preview).
