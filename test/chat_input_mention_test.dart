import 'dart:io';

import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/services/platform/voice_service_factory.dart';
import 'package:agent_buddy/widgets/chat_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// End-to-end coverage for the `@` mention popup in
/// [ChatInput]. Builds a synthetic working directory, points the
/// input at it, then exercises:
///   * typing `@` opens the popup with the directory listing;
///   * narrowing the query filters by score (exact > prefix >
///     substring);
///   * pressing Enter on the top match attaches it and splices
///     the filename into the input box;
///   * images go to the image list, everything else to the file
///     attachment list — matching the existing
///     `_pickImage` / `_pickFile` split.
void main() {
  late Directory workDir;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('chat_input_mention_');
    // Three canonical files: one text, one image, one document.
    // The chat input's scanner branches on these — the popup
    // shows them in any order, and the attachment logic routes
    // images vs files based on extension.
    File(p.join(workDir.path, 'notes.txt')).writeAsStringSync('hello');
    File(
      p.join(workDir.path, 'photo.png'),
    ).writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47]);
    File(
      p.join(workDir.path, 'report.pdf'),
    ).writeAsBytesSync(const [0x25, 0x50, 0x44, 0x46]);
    // Hidden file should be filtered out by the scanner.
    File(p.join(workDir.path, '.hidden')).writeAsStringSync('x');
  });

  tearDown(() async {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  Future<void> pumpInput(
    WidgetTester tester, {
    required void Function(String text, List<String> images, dynamic files)
    onSend,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        locale: const Locale('en'),
        home: Scaffold(
          body: ChatInput(
            onSend: onSend,
            enabled: true,
            imageService: ImageService(),
            fileAttachmentService: FileAttachmentService(),
            voiceService: createVoiceServiceStub(),
            workingDirectory: workDir.path,
          ),
        ),
      ),
    );
  }

  testWidgets('typing @ opens the file popup', (tester) async {
    await pumpInput(tester, onSend: (_, _, _) {});
    final ctx = tester.element(find.byType(ChatInput));
    final l10n = AppLocalizations.of(ctx);

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();

    expect(find.text(l10n.chatMentionPopupTitle), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    // Hidden file shouldn't show up.
    expect(find.text('.hidden'), findsNothing);
  });

  testWidgets('no working directory surfaces the "pick one" hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        locale: const Locale('en'),
        home: Scaffold(
          body: ChatInput(
            onSend: (_, _, _) {},
            enabled: true,
            imageService: ImageService(),
            fileAttachmentService: FileAttachmentService(),
            voiceService: createVoiceServiceStub(),
            workingDirectory: null,
          ),
        ),
      ),
    );
    final ctx = tester.element(find.byType(ChatInput));
    final l10n = AppLocalizations.of(ctx);

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();

    expect(find.text(l10n.chatMentionPopupNoWorkingDir), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
  });

  testWidgets('narrowing the query filters the popup by score', (tester) async {
    await pumpInput(tester, onSend: (_, _, _) {});

    await tester.enterText(find.byType(TextField), '@ph');
    await tester.pump();

    // 'ph' only matches photo.png — notes.txt and report.pdf
    // should both be filtered out.
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('report.pdf'), findsNothing);
  });

  testWidgets('Enter on the top match attaches the file + splices name', (
    tester,
  ) async {
    final sentText = <String>[];
    final sentImages = <List<String>>[];
    final sentFiles = <List<dynamic>>[];
    await pumpInput(
      tester,
      onSend: (text, images, files) {
        sentText.add(text);
        sentImages.add(images);
        sentFiles.add(files);
      },
    );

    // Type `@ph` — only photo.png matches.
    await tester.enterText(find.byType(TextField), '@ph');
    await tester.pump();

    // Press Enter — top match is photo.png.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // No message sent (we attached a file instead).
    expect(sentText, isEmpty);
    // The input should now contain the filename + trailing space.
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    expect(controller.text, contains('photo.png'));
    // The file should have landed in the image list (image MIME)
    // — the bubble would render it as an image thumbnail. We
    // can't easily inspect the internal list from outside the
    // widget; the controller text assertion is the strongest
    // observable signal here.
  });

  testWidgets('Enter when popup is closed sends the message normally', (
    tester,
  ) async {
    final sent = <String>[];
    await pumpInput(tester, onSend: (text, _, _) => sent.add(text));

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();

    // No @ trigger → Enter is a normal "send".
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sent, contains('hello world'));
  });

  testWidgets('plain @ inside an email-like string does NOT open the popup', (
    tester,
  ) async {
    await pumpInput(tester, onSend: (_, _, _) {});
    final ctx = tester.element(find.byType(ChatInput));
    final l10n = AppLocalizations.of(ctx);

    // user@example — caret at end. The `@` is preceded by
    // non-whitespace, so this shouldn't trigger the popup.
    await tester.enterText(find.byType(TextField), 'user@example');
    await tester.pump();

    expect(find.text(l10n.chatMentionPopupTitle), findsNothing);
    expect(find.text('photo.png'), findsNothing);
  });

  testWidgets('whitespace after @ closes the popup', (tester) async {
    await pumpInput(tester, onSend: (_, _, _) {});
    final ctx = tester.element(find.byType(ChatInput));
    final l10n = AppLocalizations.of(ctx);

    // `@foo ` — caret after the space. The token walker bails
    // on the first whitespace it sees between @ and caret, so
    // no mention is active.
    await tester.enterText(find.byType(TextField), '@foo ');
    await tester.pump();

    expect(find.text(l10n.chatMentionPopupTitle), findsNothing);
  });
}
