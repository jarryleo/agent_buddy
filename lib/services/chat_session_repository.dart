import 'package:hive_ce/hive.dart';

import '../models/chat_session.dart';
import '../models/chat_session_adapter.dart';
import '../models/message.dart';

/// On-disk store for [ChatSession] objects. Backed by Hive so the
/// store is cross-platform (Android / iOS / Web / Windows / macOS /
/// Linux) without any per-platform wiring — the `hive_ce_flutter`
/// init helper sets the right directory on every platform.
///
/// One box holds all sessions. Keys are the session ids; values are
/// the full [ChatSession] payload (including the message list).
///
/// Hive's lazy-load model is fine here: we only hydrate one session
/// at a time, and the session list itself is just a metadata view
/// (title + timestamp) loaded eagerly on startup.
class ChatSessionRepository {
  static const String boxName = 'chat_sessions';
  static const int _sessionTypeId = 1;

  late final Box<ChatSession> _box;
  bool _initialized = false;

  /// Whether the repo has finished opening its Hive box.
  bool get isReady => _initialized;

  /// Register the [ChatSessionAdapter] with Hive. Must be called
  /// before [open]. Safe to call multiple times.
  static void registerAdapters() {
    if (!Hive.isAdapterRegistered(_sessionTypeId)) {
      Hive.registerAdapter(ChatSessionAdapter());
    }
  }

  /// Open the underlying Hive box. Idempotent.
  Future<void> open() async {
    if (_initialized) return;
    registerAdapters();
    _box = await Hive.openBox<ChatSession>(boxName);
    _initialized = true;
  }

  /// All sessions sorted newest-first by [ChatSession.updatedAt].
  /// Returns a defensive copy; mutations on the list won't affect
  /// the store.
  List<ChatSession> list() {
    final all = _box.values.toList();
    all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all;
  }

  /// Load a single session (with its full message list). Returns
  /// null if the id is unknown.
  ChatSession? get(String id) {
    if (id.isEmpty) return null;
    return _box.get(id);
  }

  /// Persist [session]. Overwrites any existing entry with the
  /// same id.
  Future<void> save(ChatSession session) async {
    await _box.put(session.id, session);
  }

  /// Update only the message list and bump [updatedAt]. Used after
  /// the chat UI mutates a session in place.
  Future<void> updateMessages(String id, List<ChatMessage> messages) async {
    final existing = _box.get(id);
    if (existing == null) return;
    final updated = existing.copyWith(
      messages: messages,
      updatedAt: DateTime.now(),
    );
    await _box.put(id, updated);
  }

  /// Delete a session by id. No-op if the id is unknown.
  Future<void> delete(String id) async {
    if (id.isEmpty) return;
    await _box.delete(id);
  }

  /// Delete a batch of sessions. Errors on individual deletes are
  /// swallowed so a single missing id doesn't fail the whole op.
  Future<void> deleteMany(Iterable<String> ids) async {
    for (final id in ids) {
      try {
        await _box.delete(id);
      } catch (_) {}
    }
  }

  /// Total session count.
  int get length => _box.length;

  /// Close the underlying box. Tests use this for cleanup; the app
  /// itself doesn't need to call it (Hive handles it on process exit).
  Future<void> close() async {
    if (!_initialized) return;
    await _box.close();
    _initialized = false;
  }
}
