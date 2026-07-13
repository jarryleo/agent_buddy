import 'dart:async';

import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// Wraps the navigator with a bottom-right toast overlay. On
/// mobile the actual notification is handled by the OS via
/// `flutter_local_notifications`, so the overlay is a no-op there
/// (the host still mounts so the lifecycle is identical across
/// platforms). On desktop / web the host shows up to three
/// simultaneously-visible toasts that auto-dismiss after a few
/// seconds.
class NotificationHost extends StatefulWidget {
  const NotificationHost({super.key, required this.child});
  final Widget child;

  @override
  State<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends State<NotificationHost> {
  StreamSubscription<NotificationToast>? _sub;
  final List<_LiveToast> _live = [];
  static const int _maxVisible = 3;
  static const Duration _toastDuration = Duration(seconds: 4);
  static const Duration _enterDuration = Duration(milliseconds: 220);
  static const Duration _exitDuration = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    _sub = NotificationService.instance.toastStream.listen(_onToast);
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final t in _live) {
      t.timer?.cancel();
    }
    super.dispose();
  }

  void _onToast(NotificationToast t) {
    // Cap visible toasts: drop the oldest if we'd overflow.
    while (_live.length >= _maxVisible) {
      final dropped = _live.removeAt(0);
      dropped.timer?.cancel();
      dropped.exited = true;
    }
    final live = _LiveToast(
      id: DateTime.now().microsecondsSinceEpoch,
      toast: t,
    );
    setState(() => _live.add(live));
    live.timer = Timer(_toastDuration, () {
      if (!mounted) return;
      setState(() {
        live.exited = true;
      });
      Future.delayed(_exitDuration, () {
        if (!mounted) return;
        setState(() => _live.remove(live));
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Render toasts at the bottom-right of the phone frame.
        // We use Align + a Column to keep them stacked from the
        // bottom up. Sized to a reasonable max width so long
        // messages wrap instead of pushing past the phone column.
        Positioned(
          right: 12,
          bottom: 12,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [for (final t in _live) _buildToast(context, t)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToast(BuildContext context, _LiveToast live) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E2026) : Colors.white;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1A);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AnimatedSlide(
        duration: _enterDuration,
        offset: live.exited ? const Offset(0.2, 0) : Offset.zero,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          duration: live.exited ? _exitDuration : _enterDuration,
          opacity: live.exited ? 0 : 1,
          child: Material(
            color: bg,
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                live.timer?.cancel();
                setState(() {
                  live.exited = true;
                  _live.remove(live);
                });
              },
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : AppTheme.primary.withValues(alpha: 0.18),
                    width: 0.6,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.notifications_active_outlined,
                      size: 18,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            live.toast.title.isEmpty ? '通知' : live.toast.title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: fg,
                            ),
                          ),
                          if (live.toast.body.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              live.toast.body,
                              style: TextStyle(
                                fontSize: 12,
                                color: fg.withValues(alpha: 0.78),
                                height: 1.35,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.close,
                      size: 14,
                      color: fg.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveToast {
  _LiveToast({required this.id, required this.toast});
  final int id;
  final NotificationToast toast;
  Timer? timer;
  bool exited = false;
}
