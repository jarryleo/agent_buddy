import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/pet.dart';
import '../providers/pet_provider.dart';
import '../providers/settings_provider.dart';
import '../services/pet_animation_controller.dart';
import '../services/pet_service.dart';
import '../services/tools/tool_base.dart' show isDesktop;
import '../theme/app_theme.dart';
import '../widgets/spritesheet_animation.dart';
import 'settings_page.dart';

/// Settings tab for the desktop pet. Lives between the role and
/// tools tabs. Top of the page is the master toggle + petdex.dev
/// link, the body is the pet list, the bottom-right FAB opens a
/// system file picker to import a `.zip`.
class PetTab extends StatefulWidget {
  const PetTab({super.key});

  @override
  State<PetTab> createState() => _PetTabState();
}

class _PetTabState extends State<PetTab> {
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PetProvider>().ensureReady();
    });
  }

  Future<void> _togglePet(BuildContext context, bool next) async {
    final settings = context.read<SettingsProvider>();
    await settings.setShowDesktopPet(next);
  }

  Future<void> _selectPet(BuildContext context, Pet pet) async {
    final settings = context.read<SettingsProvider>();
    await settings.setActivePetId(pet.id);
    if (!settings.showDesktopPet) {
      await settings.setShowDesktopPet(true);
    }
  }

  Future<void> _import(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final provider = context.read<PetProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.petImportNeedPath)));
        return;
      }
      final pet = await provider.importFromZip(path);
      if (!context.mounted) return;
      await _selectPet(context, pet);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.petImportSuccess(pet.displayName))),
      );
    } on PetImportException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.petImportFailed(e.message))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.petImportFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _deletePet(BuildContext context, Pet pet) async {
    final l10n = AppLocalizations.of(context);
    final provider = context.read<PetProvider>();
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.petDeleteTitle),
        content: Text(l10n.petDeleteConfirm(pet.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await provider.delete(pet.id);
    if (!mounted) return;
    if (settings.activePetId == pet.id) {
      await settings.setActivePetId(null);
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.petDeletedSnackbar(pet.displayName))),
    );
  }

  Future<void> _openPetdex(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final uri = Uri.parse('https://petdex.dev/');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.petLinkFailed)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.petLinkFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsProvider>();
    final petProvider = context.watch<PetProvider>();
    final pets = petProvider.pets;
    final activeId = settings.activePetId;
    final canHavePet = isDesktop();
    return Scaffold(
      backgroundColor: context.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing || !canHavePet ? null : () => _import(context),
        icon: _importing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _Header(
            canHavePet: canHavePet,
            showPet: settings.showDesktopPet,
            onToggle: (v) => _togglePet(context, v),
            onOpenPetdex: () => _openPetdex(context),
            l10n: l10n,
          ),
          Expanded(
            child: !canHavePet
                ? EmptyHint(
                    text: l10n.petDesktopOnly,
                    icon: Icons.desktop_windows_outlined,
                  )
                : pets.isEmpty
                ? EmptyHint(text: l10n.petListEmpty, icon: Icons.pets)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                    itemCount: pets.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final pet = pets[index];
                      final active = activeId == pet.id;
                      return _PetCard(
                        pet: pet,
                        active: active,
                        onTap: () => _selectPet(context, pet),
                        onDelete: pet.isBuiltIn
                            ? null
                            : () => _deletePet(context, pet),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.canHavePet,
    required this.showPet,
    required this.onToggle,
    required this.onOpenPetdex,
    required this.l10n,
  });

  final bool canHavePet;
  final bool showPet;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpenPetdex;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pets, size: 20, color: context.textPrimary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.petMasterToggle,
                      style: TextStyle(
                        fontSize: 14,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.petMasterToggleDescription,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch.adaptive(
                value: showPet && canHavePet,
                onChanged: canHavePet ? onToggle : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: onOpenPetdex,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.link_rounded,
                    size: 16,
                    color: AppTheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'petdex.dev',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.petBrowseGallery,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 14,
                    color: context.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PetCard extends StatelessWidget {
  const _PetCard({
    required this.pet,
    required this.active,
    required this.onTap,
    required this.onDelete,
  });

  final Pet pet;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? AppTheme.primary : context.appBorder,
              width: active ? 1.4 : 0.6,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PetThumbnail(pet: pet),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pet.displayName,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (active)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              AppLocalizations.of(context).commonInUse,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (pet.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        pet.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _Badge(text: '${pet.animations.length} 动作'),
                        _Badge(text: '${pet.fps.toStringAsFixed(1)} fps'),
                        if (pet.isBuiltIn) _Badge(text: '内置'),
                      ],
                    ),
                  ],
                ),
              ),
              if (onDelete != null)
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Colors.redAccent,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: AppLocalizations.of(context).commonDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetThumbnail extends StatelessWidget {
  const _PetThumbnail({required this.pet});
  final Pet pet;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 64,
        height: 64,
        color: context.bg,
        child: Center(
          child: SizedBox(
            width: 56,
            height: 56,
            child: FittedBox(
              fit: BoxFit.contain,
              // The thumbnail needs its own controller (it lives
              // outside the pet window) — build a transient one
              // scoped to the pet's default animation. The
              // animation doesn't need to advance for a
              // static-feeling thumbnail, but we wire it up so
              // future "tap to preview" affordances still work.
              child: _ThumbnailSprite(pet: pet),
            ),
          ),
        ),
      ),
    );
  }
}

/// Static-feeling thumbnail renderer. Builds its own
/// `PetAnimationController` for the duration of the row so the
/// settings tab can drop a tiny preview next to each pet
/// without having to spin up the real pet window.
class _ThumbnailSprite extends StatefulWidget {
  const _ThumbnailSprite({required this.pet});
  final Pet pet;

  @override
  State<_ThumbnailSprite> createState() => _ThumbnailSpriteState();
}

class _ThumbnailSpriteState extends State<_ThumbnailSprite> {
  late final PetAnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = PetAnimationController(pet: widget.pet);
  }

  @override
  void didUpdateWidget(covariant _ThumbnailSprite oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pet.id != widget.pet.id) {
      _ctrl.setPet(widget.pet);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SpritesheetAnimation(controller: _ctrl);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}
