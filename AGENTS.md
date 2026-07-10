# Agent Buddy — Agent Notes

Cross-platform (android / ios / web / linux / macos / windows) Flutter app.
Phone-style UI is enforced everywhere via `lib/widgets/phone_frame.dart`
(centered, fixed-width column on wide screens).

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
- `lib/services/` — `StorageService` (SharedPreferences for settings + `ChatSessionRepository` for chat history), `ApiService` (OpenAI + Anthropic SSE, throws raw `Error:` strings on purpose for the AI), `ToolService` (HTML fetch for `fetch_web`, plus 4 unified personal-data tool dispatchers: `runCalendar` / `runReminders` / `runNotes` / `runTasks`), `LocalLlmService` (wraps `llamadart`'s `LlamaEngine` + `ChatSession` for GGUF, lazy-loaded on first chat, supports mmproj multimodal), `ToolOrchestrator` (multi-round tool-calling loop, transport-agnostic; both `ApiService` and `LocalLlmService` delegate to it so model turns can chain tool calls without manual follow-up bookkeeping), `ChatSessionRepository` (Hive-backed storage for `ChatSession` objects, cross-platform). `lib/services/platform/` holds the mobile-tool abstractions (`CalendarService` / `RemindersService` / `NotesService` / `TasksService`) plus per-platform `*_service_io.dart` MethodChannel impls and `*_service_stub.dart` fallbacks for web / desktop.
- `lib/providers/` — `ChangeNotifier`s; `ChatProvider.sendMessage(BuildContext, String)` takes context on purpose to read l10n for user-facing errors
- `lib/pages/` — top-level routes (`HomePage`, `SettingsPage` + 5 tab pages incl. `LocalProvidersTab`, `AddProviderPage`, `AddLocalProviderPage`)
- `lib/widgets/` — reusable (`PhoneFrame`, `ChatInput`, `MessageBubble`, `MarkdownContent`, `CodeBlock`, `ImagePreviewPage`, `NoFocusIconButton`)
- `lib/theme/app_theme.dart` — single light theme, iOS-leaning
- `lib/l10n/` — ARB sources + **generated** `app_localizations*.dart` (checked in, do not hand-edit)

## Repo-specific gotchas

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
- One smoke test exists (`ApiService` constructs) plus service-layer coverage for the new platform tools: `notes_service_test.dart`, `tasks_service_test.dart`, `platform_tools_test.dart` (end-to-end via `ToolService`), `platform_calendar_reminders_test.dart` (validation paths + stub-translation). Total ~59 tests.
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
- All four tools return JSON envelopes (`{action, count, items[]}` for list; `{action, item}` for get/create; `{action, found, item}` for missing; `{action, ok}` for delete). The model's view of the tool is in `_buildToolsSchema` (`lib/providers/chat_provider.dart`); the dispatcher is `ToolService.runCalendar` / `runReminders` / `runNotes` / `runTasks`. Errors from native bridges (permission denied, no todo calendar, OS not supported) are translated to `ToolException` so the model can react.
- On non-mobile platforms the `*_service_io.dart` factory (`calendar_service_factory.dart` / `reminders_service_factory.dart`) returns a `*_service_stub.dart` that throws `UnsupportedError` → caught and rethrown as `ToolException('... not supported on this platform')`. The schema is gated on `ChatProvider._isMobilePlatform` so the model never even sees `calendar` / `reminders` on web / desktop.

## Scope / what "done" looks like

`README.md` ends with a `代办事项` (TODO) list — treat that as the current feature backlog, not docs. v1 is shipped (chat + settings + provider + role + tools + skill, i18n, markdown rendering, code highlighting, image preview).
