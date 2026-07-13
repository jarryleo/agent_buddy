import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/image_service.dart';
import '../services/local_llm_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_input.dart';
import '../widgets/message_bubble.dart';
import '../widgets/no_focus_icon_button.dart';
import '../widgets/session_manager_sheet.dart';
import 'auto_scroll_policy.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Scroll controller for the chat list. Recreated on every
  /// session switch (see [_buildScrollController]) so a brand-new
  /// ListView gets a brand-new controller. The previous
  /// implementation reused one controller across sessions; when
  /// the user switched sessions the ListView was rebuilt in-place
  /// (same widget type + same position) and Flutter briefly
  /// attached the controller to two different ScrollPositions,
  /// which trips the `ScrollController` "_positions.length == 1"
  /// assertion during the auto-scroll post-frame callback.
  ScrollController? _scrollController;
  String? _scrollControllerSessionId;

  /// Pure-Dart policy that decides whether to auto-scroll on
  /// each frame. Lives in its own file so it can be unit-tested
  /// without spinning up the widget tree.
  final AutoScrollPolicy _autoScroll = AutoScrollPolicy();

  /// Returns a [ScrollController] tied to [activeSessionId].
  /// When the active session changes we dispose the previous
  /// controller (after the old ListView detaches) and mint a
  /// fresh one. Same-session rebuilds reuse the same controller
  /// and Flutter reuses the ListView element.
  ScrollController _buildScrollController(String activeSessionId) {
    if (_scrollController == null ||
        _scrollControllerSessionId != activeSessionId) {
      // Dispose the previous controller. The previous ListView
      // (if any) has already detached by the time we land here,
      // because its `key` was different from the current one;
      // disposing on the build path is therefore safe.
      _scrollController?.dispose();
      _scrollController = ScrollController()..addListener(_onScrollChanged);
      _scrollControllerSessionId = activeSessionId;
      // A fresh conversation always opens at the bottom.
      _autoScroll.reset();
    }
    return _scrollController!;
  }

  void _onScrollChanged() {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) return;
    final pos = controller.position;
    // 32px slack so micro-jitter from typing-into-the-input-box
    // doesn't reset the flag every frame.
    final atBottom = pos.pixels >= pos.maxScrollExtent - 32;
    if (atBottom) {
      _autoScroll.markUserAtBottom();
    } else {
      _autoScroll.markUserNotAtBottom();
    }
  }

  /// Groups consecutive assistant messages that are tool-only (have
  /// tool calls but no content and no thinking) into a single list
  /// for the [MessageBubble] to render as a collapsed group.
  /// Non-tool-only messages are returned as-is.
  bool _isToolOnly(ChatMessage m) {
    return m.role == MessageRole.assistant &&
        m.toolCalls.isNotEmpty &&
        m.content.isEmpty &&
        m.thinking.isEmpty;
  }

  List<Object> _groupedMessages(List<ChatMessage> messages) {
    final result = <Object>[];
    List<ChatMessage>? currentGroup;
    for (final m in messages) {
      if (_isToolOnly(m)) {
        (currentGroup ??= []).add(m);
      } else {
        if (currentGroup != null) {
          result.add(currentGroup);
          currentGroup = null;
        }
        result.add(m);
      }
    }
    if (currentGroup != null) {
      result.add(currentGroup);
    }
    return result;
  }

  @override
  void dispose() {
    _scrollController?.dispose();
    _scrollController = null;
    _scrollControllerSessionId = null;
    super.dispose();
  }

  /// Public hook for the chat input. The user explicitly asked
  /// to send a message; the next auto-scroll MUST land at the
  /// bottom even if the user was reading older history.
  void requestForceScrollToBottom() {
    _autoScroll.requestForceScrollToBottom();
  }

  /// Schedules an auto-scroll to the bottom of the list, then
  /// runs the decision in the post-frame callback (so the
  /// `maxScrollExtent` reflects the latest laid-out content).
  void _scheduleAutoScroll(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Recapture the controller from the field. The
      // `controller` reference captured at schedule time may
      // be stale if the active session changed in the
      // meantime; the field has already been replaced.
      final live = _scrollController;
      if (live == null || !live.hasClients) return;
      final pos = live.position;
      final target = _autoScroll.schedule(
        pixels: pos.pixels,
        maxScrollExtent: pos.maxScrollExtent,
      );
      if (target == null) {
        // schedule() may have decided to skip (already at
        // bottom, user scrolled up between frames, etc.) —
        // either way nothing to do.
        return;
      }
      live.jumpTo(target);
      _autoScroll.markJumped();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        leading: NoFocusIconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: l10n.homeSettingsTooltip,
          onPressed: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => SettingsPage()));
          },
        ),
        title: Consumer<SettingsProvider>(
          builder: (context, settings, _) {
            final role = settings.activeRole;
            final title = role?.name ?? l10n.appTitle;
            final String subtitle;
            if (settings.useLocalModel) {
              final lp = settings.activeLocalProvider;
              subtitle = lp == null
                  ? l10n.homeNoModel
                  : l10n.homeProviderModel(lp.name, lp.displayModelName);
            } else {
              final provider = settings.activeProvider;
              subtitle = provider == null
                  ? l10n.homeNoModel
                  : l10n.homeProviderModel(
                      provider.name,
                      provider.selectedModel ?? l10n.homeNoModelSelected,
                    );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.textSecondary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          Consumer<ChatProvider>(
            builder: (context, chat, _) {
              return NoFocusIconButton(
                icon: const Icon(Icons.forum_outlined),
                tooltip: l10n.homeSessionsTooltip,
                onPressed: () => SessionManagerSheet.show(context),
              );
            },
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chat, _) {
          final activeSessionId = chat.activeSessionId;
          // `visibleMessages` filters out hidden system messages
          // (e.g. the synthetic "[系统计时触发] …" reminder the
          // chat provider appends when a timer fires) so the
          // ListView never tries to render them as user bubbles.
          // The full `messages` list (including hidden ones) is
          // still used by the request builder inside
          // `_runAssistantTurn` so the model still sees them.
          final messages = chat.visibleMessages;
          final sending = chat.sending;
          // Build a controller bound to the current session. When
          // `activeSessionId` changes the ListView (below) is
          // rebuilt from scratch with a new key, so a brand-new
          // controller is created and the old one is disposed by
          // Flutter when the old ListView is deactivated.
          final scrollController = activeSessionId.isEmpty
              ? null
              : _buildScrollController(activeSessionId);
          if (scrollController != null) {
            _scheduleAutoScroll(scrollController);
          }
          return Column(
            children: [
              const _LocalModelStatusBar(),
              Expanded(
                child: messages.isEmpty
                    ? _EmptyState(l10n: l10n)
                    : ListView.builder(
                        // Keyed to the session id so a session
                        // switch forces a fresh ListView (and
                        // therefore a fresh ScrollController
                        // binding). This is the primary fix for
                        // the "ScrollController attached to
                        // multiple scroll views" assertion that
                        // fired during the post-frame
                        // auto-scroll callback after a session
                        // change.
                        key: ValueKey('chat_list_$activeSessionId'),
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        // addRepaintBoundaries: each item is its
                        // own paint layer; the ListView's
                        // recycling cache won't repaint a message
                        // that didn't change, even when neighbors
                        // are streaming.
                        addRepaintBoundaries: true,
                        // addAutomaticKeepAlives defaults to true,
                        // which keeps every message mounted even
                        // when it scrolls off-screen. With long
                        // histories that's wasteful (one
                        // AnimationController per off-screen
                        // bubble). Disable it; we don't rely on
                        // out-of-view widgets staying alive.
                        addAutomaticKeepAlives: false,
                        itemCount: _groupedMessages(messages).length,
                        itemBuilder: (context, index) {
                          final item = _groupedMessages(messages)[index];
                          if (item is List<ChatMessage>) {
                            return MessageBubble(
                              key: ValueKey(
                                'tool_group_${item.first.id}_${item.length}',
                              ),
                              message: item.first,
                              groupedToolMessages: item,
                              onCopy: (text) async {
                                await Clipboard.setData(
                                  ClipboardData(text: text),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l10n.homeCopied),
                                      duration: Duration(milliseconds: 1200),
                                    ),
                                  );
                                }
                              },
                            );
                          }
                          final m = item as ChatMessage;
                          return MessageBubble(
                            // Stable key: the State (and its
                            // ScrollController) must be tied to
                            // the message's identity, not its
                            // position in the list. Without this,
                            // Flutter reuses the State across
                            // messages when the list reorders /
                            // grows, and the controller gets
                            // attached to two different
                            // SingleChildScrollViews
                            // simultaneously — which throws
                            // "_positions.length == 1".
                            key: ValueKey('msg_${m.id}'),
                            message: m,
                            onCopy: (text) async {
                              await Clipboard.setData(
                                ClipboardData(text: text),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.homeCopied),
                                    duration: Duration(milliseconds: 1200),
                                  ),
                                );
                              }
                            },
                          );
                        },
                      ),
              ),
              // We read the SettingsProvider for the `ready` flag
              // (and the ChatProvider for `sending`); a separate
              // Selector-style wrapper isn't worth the boilerplate
              // here, but we DO use `read` (not `watch`) so the
              // input widget doesn't rebuild on settings changes.
              _ChatInputArea(
                chat: chat,
                sending: sending,
                onBeforeSend: requestForceScrollToBottom,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.l10n});
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.smart_toy_outlined,
                size: 36,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.homeEmptyTitle,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.homeEmptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: context.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim bar at the top of the chat showing local-model engine state.
///
/// - Hidden when the user isn't on a local model at all.
/// - Indeterminate progress + label while the model is loading.
/// - Red error bar with Retry / Dismiss when the last load attempt
///   failed (so the user isn't left staring at an idle spinner).
/// - "Release model" button once a model is loaded (so the user can
///   free RAM/memory-mapping before swapping providers).
/// Wraps the input + bottom-of-screen controls. Reads its
/// dependencies via `Provider.read` (not `watch`) so changes to
/// the SettingsProvider don't rebuild the input every time the
/// user toggles a setting; the consumer above already rebuilds
/// the input whenever `chat.sending` flips, which is the only
/// input-related signal we care about.
class _ChatInputArea extends StatelessWidget {
  const _ChatInputArea({
    required this.chat,
    required this.sending,
    required this.onBeforeSend,
  });

  final ChatProvider chat;
  final bool sending;
  final VoidCallback onBeforeSend;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsProvider>();
    final bool ready;
    if (settings.useLocalModel) {
      ready = settings.activeLocalProvider != null;
    } else {
      final provider = settings.activeProvider;
      ready =
          provider != null &&
          (provider.selectedModel != null || provider.models.isNotEmpty);
    }
    return ChatInput(
      enabled: ready && !sending,
      sending: sending,
      imageService: context.read<ImageService>(),
      onStop: () => chat.stopGeneration(),
      onSend: (text, imagePaths) {
        // Mark the next auto-scroll as "force" so the latest
        // message comes into view even if the user had
        // scrolled up. Must run before sendMessage so the
        // post-frame callback (scheduled inside the rebuild
        // triggered by sendMessage's first notifyListeners)
        // sees the flag.
        onBeforeSend();
        chat.sendMessage(context, text, imagePaths: imagePaths);
      },
    );
  }
}

class _LocalModelStatusBar extends StatelessWidget {
  const _LocalModelStatusBar();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsProvider>();
    if (!settings.useLocalModel) return const SizedBox.shrink();
    final local = context.watch<LocalLlmService>();

    if (local.isLoading) {
      return Container(
        width: double.infinity,
        color: AppTheme.primary.withValues(alpha: 0.06),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.homeLocalModelLoading,
                style: TextStyle(fontSize: 12, color: context.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    if (local.loadError != null) {
      return Container(
        width: double.infinity,
        color: Colors.red.withValues(alpha: 0.08),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.homeLocalModelLoadFailed(local.loadError.toString()),
                style: const TextStyle(fontSize: 12, color: Colors.red),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () {
                final svc = context.read<LocalLlmService>();
                final lp = context.read<SettingsProvider>().activeLocalProvider;
                svc.clearLoadError();
                if (lp != null) {
                  // Fire and forget; the status bar will flip to the
                  // loading state via the ChangeNotifier notification.
                  svc.ensureLoaded(lp).catchError((_) {
                    // Error is captured into loadError by ensureLoaded.
                    return null;
                  });
                }
              },
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                l10n.homeLocalModelRetry,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => context.read<LocalLlmService>().clearLoadError(),
              style: TextButton.styleFrom(
                foregroundColor: context.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                l10n.homeLocalModelDismiss,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (local.isReady) {
      return Container(
        width: double.infinity,
        color: AppTheme.primary.withValues(alpha: 0.06),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: AppTheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.homeLocalModelReady,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Tooltip(
              message: l10n.homeLocalModelReleaseTooltip,
              child: TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await context.read<LocalLlmService>().releaseModel();
                  if (!context.mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(l10n.homeLocalModelReleased),
                      duration: const Duration(milliseconds: 1200),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.memory_outlined, size: 16),
                label: Text(
                  l10n.homeLocalModelRelease,
                  style: const TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
