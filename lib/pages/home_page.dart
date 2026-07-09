import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/image_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_input.dart';
import '../widgets/message_bubble.dart';
import '../widgets/no_focus_icon_button.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        leading: NoFocusIconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: l10n.homeSettingsTooltip,
          onPressed: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
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
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondary,
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
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: l10n.homeClearChatTooltip,
                onPressed: chat.messages.isEmpty
                    ? null
                    : () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(l10n.homeClearChatTitle),
                            content: Text(l10n.homeClearChatMessage),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text(l10n.commonCancel),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text(l10n.homeClearChatConfirm),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await chat.clearMessages();
                        }
                      },
              );
            },
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chat, _) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
          return Column(
            children: [
              Expanded(
                child: chat.messages.isEmpty
                    ? _EmptyState(l10n: l10n)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: chat.messages.length,
                        itemBuilder: (context, index) {
                          final m = chat.messages[index];
                          return MessageBubble(
                            message: m,
                            onCopy: (text) async {
                              await Clipboard.setData(
                                ClipboardData(text: text),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.homeCopied),
                                    duration: const Duration(
                                      milliseconds: 1200,
                                    ),
                                  ),
                                );
                              }
                            },
                          );
                        },
                      ),
              ),
              Consumer<SettingsProvider>(
                builder: (context, settings, _) {
                  final bool ready;
                  if (settings.useLocalModel) {
                    ready = settings.activeLocalProvider != null;
                  } else {
                    final provider = settings.activeProvider;
                    ready =
                        provider != null &&
                        (provider.selectedModel != null ||
                            provider.models.isNotEmpty);
                  }
                  return ChatInput(
                    enabled: ready && !chat.sending,
                    imageService: context.read<ImageService>(),
                    onSend: (text, imagePaths) {
                      chat.sendMessage(context, text, imagePaths: imagePaths);
                    },
                  );
                },
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
              child: const Icon(
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
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
