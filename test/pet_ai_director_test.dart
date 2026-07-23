import 'package:agent_buddy/services/pet_ai_director.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePetTimeline', () {
    test('returns empty list for empty input', () {
      expect(parsePetTimeline(''), isEmpty);
      expect(parsePetTimeline('   \n  '), isEmpty);
    });

    test('returns empty list for non-JSON input', () {
      expect(parsePetTimeline('hello world'), isEmpty);
    });

    test('returns empty list for JSON that is not an array', () {
      expect(parsePetTimeline('{"foo": "bar"}'), isEmpty);
    });

    test('parses a clean mix of move/speak/act entries', () {
      final raw = '''
[
  {"time": "00:10", "type": "move", "x": 100, "y": 200, "speed": 60},
  {"time": "00:25", "type": "speak", "text": "Hi!"},
  {"time": "00:40", "type": "act", "name": "waving"},
  {"time": "00:55", "type": "act", "name": "jumping", "repeats": 3},
  {"time": "01:10", "type": "speak", "text": "Still here"},
  {"time": "01:25", "type": "move", "x": 800, "y": 600},
  {"time": "01:40", "type": "act", "name": "failed"},
  {"time": "01:55", "type": "speak", "text": "What was that?"},
  {"time": "02:10", "type": "move", "x": 400, "y": 400},
  {"time": "02:25", "type": "act", "name": "jumping"}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      expect(out[0].type, PetBehaviorType.move);
      expect(out[0].offsetSeconds, 10);
      expect(out[0].raw['x'], 100);
      expect(out[0].raw['y'], 200);
      expect(out[0].raw['speed'], 60);
      expect(out[1].type, PetBehaviorType.speak);
      expect(out[1].raw['text'], 'Hi!');
      expect(out[2].type, PetBehaviorType.act);
      expect(out[2].raw['name'], 'waving');
      expect(out[2].raw['repeats'], 1);
      expect(out[3].raw['repeats'], 3);
    });

    test('strips markdown code fences', () {
      final raw = '''
```json
[
  {"time": "00:10", "type": "speak", "text": "A"},
  {"time": "00:25", "type": "speak", "text": "B"},
  {"time": "00:40", "type": "speak", "text": "C"},
  {"time": "00:55", "type": "speak", "text": "D"},
  {"time": "01:10", "type": "speak", "text": "E"},
  {"time": "01:25", "type": "speak", "text": "F"},
  {"time": "01:40", "type": "speak", "text": "G"},
  {"time": "01:55", "type": "speak", "text": "H"},
  {"time": "02:10", "type": "speak", "text": "I"},
  {"time": "02:25", "type": "speak", "text": "J"}
]
```
''';
      expect(parsePetTimeline(raw), hasLength(10));
    });

    test('tolerates a preamble before the JSON array', () {
      final raw = '''Sure thing, here is a timeline:
[
  {"time": 10, "type": "speak", "text": "A"},
  {"time": 25, "type": "speak", "text": "B"},
  {"time": 40, "type": "speak", "text": "C"},
  {"time": 55, "type": "speak", "text": "D"},
  {"time": 70, "type": "speak", "text": "E"},
  {"time": 85, "type": "speak", "text": "F"},
  {"time": 100, "type": "speak", "text": "G"},
  {"time": 115, "type": "speak", "text": "H"},
  {"time": 130, "type": "speak", "text": "I"},
  {"time": 145, "type": "speak", "text": "J"}
]''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      expect(out[0].offsetSeconds, 10);
    });

    test('rejects fewer than 10 entries', () {
      final raw = '''
[
  {"time": "00:10", "type": "speak", "text": "A"},
  {"time": "00:25", "type": "speak", "text": "B"}
]
''';
      expect(parsePetTimeline(raw), isEmpty);
    });

    test('rejects entries with unknown action names', () {
      final raw = '''
[
  {"time": "00:10", "type": "speak", "text": "A"},
  {"time": "00:25", "type": "speak", "text": "B"},
  {"time": "00:40", "type": "speak", "text": "C"},
  {"time": "00:55", "type": "speak", "text": "D"},
  {"time": "01:10", "type": "speak", "text": "E"},
  {"time": "01:25", "type": "speak", "text": "F"},
  {"time": "01:40", "type": "speak", "text": "G"},
  {"time": "01:55", "type": "speak", "text": "H"},
  {"time": "02:10", "type": "speak", "text": "I"},
  {"time": "02:25", "type": "act", "name": "idle"}
]
''';
      expect(parsePetTimeline(raw), isEmpty);
    });

    test('clamps repeats to 1..5 for jumping', () {
      final raw = '''
[
  {"time": "00:10", "type": "act", "name": "jumping", "repeats": 99},
  {"time": "00:25", "type": "act", "name": "jumping", "repeats": -3},
  {"time": "00:40", "type": "act", "name": "jumping", "repeats": 0},
  {"time": "00:55", "type": "act", "name": "jumping"},
  {"time": "01:10", "type": "act", "name": "jumping"},
  {"time": "01:25", "type": "act", "name": "jumping"},
  {"time": "01:40", "type": "act", "name": "jumping"},
  {"time": "01:55", "type": "act", "name": "jumping"},
  {"time": "02:10", "type": "act", "name": "jumping"},
  {"time": "02:25", "type": "act", "name": "jumping"}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      expect(out[0].raw['repeats'], 5);
      expect(out[1].raw['repeats'], 1);
      expect(out[2].raw['repeats'], 1);
    });

    test('clamps speed to 30..240', () {
      final raw = '''
[
  {"time": "00:10", "type": "move", "x": 0, "y": 0, "speed": 5},
  {"time": "00:25", "type": "move", "x": 0, "y": 0, "speed": 9999},
  {"time": "00:40", "type": "move", "x": 0, "y": 0},
  {"time": "00:55", "type": "move", "x": 100, "y": 100},
  {"time": "01:10", "type": "move", "x": 100, "y": 100},
  {"time": "01:25", "type": "move", "x": 100, "y": 100},
  {"time": "01:40", "type": "move", "x": 100, "y": 100},
  {"time": "01:55", "type": "move", "x": 100, "y": 100},
  {"time": "02:10", "type": "move", "x": 100, "y": 100},
  {"time": "02:25", "type": "move", "x": 100, "y": 100}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      expect(out[0].raw['speed'], 30);
      expect(out[1].raw['speed'], 240);
      expect(out[2].raw['speed'], 80); // default
    });

    test('rejects entries with offset > 300s', () {
      final raw = '''
[
  {"time": "00:10", "type": "speak", "text": "A"},
  {"time": "00:25", "type": "speak", "text": "B"},
  {"time": "00:40", "type": "speak", "text": "C"},
  {"time": "00:55", "type": "speak", "text": "D"},
  {"time": "01:10", "type": "speak", "text": "E"},
  {"time": "01:25", "type": "speak", "text": "F"},
  {"time": "01:40", "type": "speak", "text": "G"},
  {"time": "01:55", "type": "speak", "text": "H"},
  {"time": "02:10", "type": "speak", "text": "I"},
  {"time": "06:00", "type": "speak", "text": "J"}
]
''';
      expect(parsePetTimeline(raw), isEmpty);
    });

    test('auto-pads entries that are too close together', () {
      final raw = '''
[
  {"time": "00:10", "type": "speak", "text": "A"},
  {"time": "00:11", "type": "speak", "text": "B"},
  {"time": "00:25", "type": "speak", "text": "C"},
  {"time": "00:40", "type": "speak", "text": "D"},
  {"time": "00:55", "type": "speak", "text": "E"},
  {"time": "01:10", "type": "speak", "text": "F"},
  {"time": "01:25", "type": "speak", "text": "G"},
  {"time": "01:40", "type": "speak", "text": "H"},
  {"time": "01:55", "type": "speak", "text": "I"},
  {"time": "02:10", "type": "speak", "text": "J"}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      // The second entry was at 00:11 (only 1s after 00:10) — it
      // should have been bumped to 00:20 (10s gap).
      expect(out[1].offsetSeconds, 20);
    });

    test('drops entries with invalid time / missing type', () {
      final raw = '''
[
  {"time": "00:10", "type": "speak", "text": "A"},
  {"time": "00:25", "type": "speak", "text": "B"},
  {"time": "00:40", "type": "speak", "text": "C"},
  {"time": "00:55", "type": "speak", "text": "D"},
  {"time": "01:10", "type": "speak", "text": "E"},
  {"time": "01:25", "type": "speak", "text": "F"},
  {"time": "01:40", "type": "speak", "text": "G"},
  {"time": "01:55", "type": "speak", "text": "H"},
  {"time": "02:10", "type": "speak", "text": "I"},
  {"time": "foo", "type": "speak", "text": "J"},
  {"time": "02:25", "type": "speak", "text": "K"}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
    });

    test('symbolic names normalise to the canonical petdex names', () {
      final raw = '''
[
  {"time": "00:10", "type": "act", "name": "wave"},
  {"time": "00:25", "type": "act", "name": "jump"},
  {"time": "00:40", "type": "act", "name": "fail"},
  {"time": "00:55", "type": "act", "name": "waving"},
  {"time": "01:10", "type": "act", "name": "jumping"},
  {"time": "01:25", "type": "act", "name": "failed"},
  {"time": "01:40", "type": "act", "name": "wave"},
  {"time": "01:55", "type": "act", "name": "jump"},
  {"time": "02:10", "type": "act", "name": "fail"},
  {"time": "02:25", "type": "act", "name": "waving"}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      expect(out[0].raw['name'], 'waving');
      expect(out[1].raw['name'], 'jumping');
      expect(out[2].raw['name'], 'failed');
    });

    test('keeps the direction of move entries unchanged', () {
      final raw = '''
[
  {"time": "00:10", "type": "move", "x": 100, "y": 200},
  {"time": "00:25", "type": "move", "x": 100, "y": 200},
  {"time": "00:40", "type": "move", "x": 100, "y": 200},
  {"time": "00:55", "type": "move", "x": 100, "y": 200},
  {"time": "01:10", "type": "move", "x": 100, "y": 200},
  {"time": "01:25", "type": "move", "x": 100, "y": 200},
  {"time": "01:40", "type": "move", "x": 100, "y": 200},
  {"time": "01:55", "type": "move", "x": 100, "y": 200},
  {"time": "02:10", "type": "move", "x": 100, "y": 200},
  {"time": "02:25", "type": "move", "x": 100, "y": 200}
]
''';
      final out = parsePetTimeline(raw);
      expect(out, hasLength(10));
      for (final b in out) {
        expect(b.type, PetBehaviorType.move);
      }
    });
  });
}
