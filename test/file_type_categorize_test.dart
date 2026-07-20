import 'package:agent_buddy/models/file_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('categorizeFile', () {
    test('maps text/* mime types to ModelFileType.text', () {
      expect(
        categorizeFile(name: 'notes.txt', mimeType: 'text/plain'),
        AgentFileType.text,
      );
      expect(
        categorizeFile(name: 'page.html', mimeType: 'text/html'),
        AgentFileType.text,
      );
      expect(
        categorizeFile(name: 'styles.css', mimeType: 'text/css'),
        AgentFileType.text,
      );
    });

    test('maps structured text mime types to text', () {
      expect(
        categorizeFile(name: 'config.json', mimeType: 'application/json'),
        AgentFileType.text,
      );
      expect(
        categorizeFile(name: 'data.xml', mimeType: 'application/xml'),
        AgentFileType.text,
      );
      expect(
        categorizeFile(name: 'config.yaml', mimeType: 'application/yaml'),
        AgentFileType.text,
      );
      expect(
        categorizeFile(name: 'main.js', mimeType: 'application/javascript'),
        AgentFileType.text,
      );
    });

    test('maps image/* mime types to image', () {
      expect(
        categorizeFile(name: 'photo.png', mimeType: 'image/png'),
        AgentFileType.image,
      );
      expect(
        categorizeFile(name: 'photo.jpg', mimeType: 'image/jpeg'),
        AgentFileType.image,
      );
      expect(
        categorizeFile(name: 'sticker.webp', mimeType: 'image/webp'),
        AgentFileType.image,
      );
    });

    test('maps audio/* mime types to audio', () {
      expect(
        categorizeFile(name: 'song.mp3', mimeType: 'audio/mpeg'),
        AgentFileType.audio,
      );
      expect(
        categorizeFile(name: 'recording.wav', mimeType: 'audio/wav'),
        AgentFileType.audio,
      );
      expect(
        categorizeFile(name: 'voice.m4a', mimeType: 'audio/mp4'),
        AgentFileType.audio,
      );
    });

    test('maps video/* mime types to video', () {
      expect(
        categorizeFile(name: 'clip.mp4', mimeType: 'video/mp4'),
        AgentFileType.video,
      );
      expect(
        categorizeFile(name: 'movie.mov', mimeType: 'video/quicktime'),
        AgentFileType.video,
      );
    });

    test('maps generic document types to document', () {
      expect(
        categorizeFile(name: 'report.pdf', mimeType: 'application/pdf'),
        AgentFileType.document,
      );
      expect(
        categorizeFile(name: 'data.xlsx', mimeType: 'application/vnd.ms-excel'),
        AgentFileType.document,
      );
    });

    test('falls back to extension when mime type is empty / octet-stream', () {
      expect(
        categorizeFile(name: 'code.dart', mimeType: 'application/octet-stream'),
        AgentFileType.text,
      );
      expect(
        categorizeFile(name: 'photo.png', mimeType: 'application/octet-stream'),
        AgentFileType.image,
      );
      expect(
        categorizeFile(name: 'song.mp3', mimeType: ''),
        AgentFileType.audio,
      );
      expect(
        categorizeFile(name: 'movie.mp4', mimeType: ''),
        AgentFileType.video,
      );
    });

    test('returns document for unknown extensions', () {
      expect(
        categorizeFile(name: 'random.xyz', mimeType: ''),
        AgentFileType.document,
      );
      expect(
        categorizeFile(name: 'README', mimeType: ''),
        AgentFileType.document,
      );
    });

    test('ignores case in mime type', () {
      expect(
        categorizeFile(name: 'photo.png', mimeType: 'IMAGE/PNG'),
        AgentFileType.image,
      );
      expect(
        categorizeFile(name: 'song.mp3', mimeType: 'Audio/MPEG'),
        AgentFileType.audio,
      );
    });
  });

  group('AgentFileType enum', () {
    test('has five categories', () {
      expect(AgentFileType.values, hasLength(5));
      expect(AgentFileType.values, containsAll(AgentFileType.values));
    });

    test('values are stable and named', () {
      expect(AgentFileType.text.name, 'text');
      expect(AgentFileType.image.name, 'image');
      expect(AgentFileType.audio.name, 'audio');
      expect(AgentFileType.video.name, 'video');
      expect(AgentFileType.document.name, 'document');
    });
  });
}
