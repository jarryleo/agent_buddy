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
- `lib/models/` — plain Dart models with `toJson` / `fromJson` for SharedPreferences (incl. `LocalProvider` for on-device GGUF models)
- `lib/services/` — `StorageService` (SharedPreferences), `ApiService` (OpenAI + Anthropic SSE, throws raw `Error:` strings on purpose for the AI), `ToolService` (HTML fetch for `fetch_web`), `LocalLlmService` (wraps `llamadart`'s `LlamaEngine` + `ChatSession` for GGUF, lazy-loaded on first chat, supports mmproj multimodal)
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
- Only one smoke test exists (`ApiService` constructs). The bar is low.
- `StorageService` requires `await init()` first; a bare `new StorageService()` will throw on first read. Don't try to test providers without mocking `SharedPreferences` (`SharedPreferences.setMockInitialValues({})`).

### Local models (llamadart / GGUF)
- `LocalLlmService` is a thin wrapper around `LlamaEngine` + `ChatSession`. The model is loaded **lazily on the first chat** after the user enables `useLocalModel` and has an active local provider — never at app startup, never on save.
- The model path, mmproj path, context size, temperature, GPU layers and max-tokens are stored in `LocalProvider` (SharedPreferences). The first time the user actually sends a message, `ensureLoaded()` is called and the engine is held in memory for subsequent turns; it's disposed on app teardown.
- Images attached to a chat message are passed through as `LlamaImageContent(path: ...)` pointing at the local file already cached by `ImageService`. Remote URLs / base64 data URLs are not used (the engine prefers file paths on native backends).
- The llmamadart native-assets hook downloads runtime archives on first build per platform — first build after adding the dep is slow (similar to Gradle cold start). Don't be surprised by a multi-minute first compile.

## Scope / what "done" looks like

`README.md` ends with a `代办事项` (TODO) list — treat that as the current feature backlog, not docs. v1 is shipped (chat + settings + provider + role + tools + skill, i18n, markdown rendering, code highlighting, image preview).
