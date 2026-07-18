import 'voice_service.dart';
import 'voice_service_impl.dart' as impl;
import 'voice_service_stub.dart' as stub;

/// Builds the platform-appropriate [VoiceService].
///
/// `stts` is a pure-Dart plugin that runs on every Flutter target
/// (android / ios / web / macOS / Windows), so we use the same
/// implementation everywhere. The split between `impl` and `stub`
/// exists only so tests can inject a fake without touching the
/// microphone plugin or `dart:io`.
VoiceService createVoiceService() => impl.VoiceServiceImpl();

VoiceService createVoiceServiceStub() => stub.VoiceServiceStub();
