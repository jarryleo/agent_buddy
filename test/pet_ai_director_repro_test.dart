import 'package:agent_buddy/services/pet_ai_director.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replays the exact JSON from the user bug report (third example)', () {
    final raw = '''
[
  {"time":"00:00","type":"speak","text":"嘿嘿，又到了专心写代码的时间啦～"},
  {"time":"00:15","type":"act","name":"waving"},
  {"time":"00:35","type":"move","x":420,"y":380,"speed":70},
  {"time":"01:05","type":"speak","text":"咦，这段代码看起来有点眼熟呢……"},
  {"time":"01:25","type":"act","name":"jumping","repeats":2},
  {"time":"01:55","type":"move","x":260,"y":520,"speed":60},
  {"time":"02:20","type":"speak","text":"要记得多喝水哦，程序员也要好好休息～"},
  {"time":"02:45","type":"act","name":"failed"},
  {"time":"03:10","type":"speak","text":"呜呜，bug 不要跑嘛！"},
  {"time":"03:30","type":"move","x":540,"y":450,"speed":80},
  {"time":"03:55","type":"act","name":"waving"},
  {"time":"04:20","type":"speak","text":"再坚持一下，马上就能跑通啦！"},
  {"time":"04:40","type":"act","name":"jumping","repeats":3},
  {"time":"05:00","type":"move","x":380,"y":600,"speed":70}
]
''';
    final out = parsePetTimeline(raw);
    expect(out, hasLength(14));
  });

  test('handles JSON missing the trailing ] (model truncated output)', () {
    // The model sometimes forgets to close the JSON array.
    // The exact pattern we see in the user's log: the JSON
    // ends with `}` but no `]`. The parser should be
    // tolerant and treat the whole `[{...}, ...{...}` as
    // a valid array.
    final raw = '''
[
  {"time": "00:05", "type": "act", "name": "waving"},
  {"time": "00:20", "type": "speak", "text": "嘿嘿，今天也要努力写代码哦～"},
  {"time": "00:40", "type": "move", "x": 400, "y": 300, "speed": 60},
  {"time": "01:00", "type": "act", "name": "jumping", "repeats": 2},
  {"time": "01:25", "type": "speak", "text": "主人想喝杯茶吗？我帮你盯着屏幕！"},
  {"time": "01:50", "type": "move", "x": 200, "y": 400, "speed": 80},
  {"time": "02:15", "type": "act", "name": "jumping", "repeats": 1},
  {"time": "02:35", "type": "speak", "text": "这个 bug 看起来有点眼熟……让我想想！"},
  {"time": "03:00", "type": "move", "x": 350, "y": 250, "speed": 70},
  {"time": "03:25", "type": "act", "name": "failed"},
  {"time": "03:45", "type": "speak", "text": "呜呜，运行失败了……但我不会放弃的！"},
  {"time": "04:10", "type": "move", "x": 300, "y": 350, "speed": 50},
  {"time": "04:35", "type": "act", "name": "jumping", "repeats": 3},
  {"time": "04:55", "type": "speak", "text": "快到休息时间啦，主人记得活动活动脖子～"}
''';
    final out = parsePetTimeline(raw);
    expect(out, hasLength(14));
  });

  test('still parses a JSON array that ends with a closing ]', () {
    final raw = '''
[
  {"time": "00:05", "type": "act", "name": "waving"},
  {"time": "00:20", "type": "speak", "text": "hi"},
  {"time": "00:40", "type": "move", "x": 100, "y": 200, "speed": 60},
  {"time": "01:00", "type": "act", "name": "jumping"},
  {"time": "01:25", "type": "speak", "text": "hi"},
  {"time": "01:50", "type": "move", "x": 100, "y": 200},
  {"time": "02:15", "type": "act", "name": "failed"},
  {"time": "02:35", "type": "speak", "text": "hi"},
  {"time": "03:00", "type": "move", "x": 100, "y": 200},
  {"time": "03:25", "type": "act", "name": "waving"},
  {"time": "03:45", "type": "speak", "text": "hi"},
  {"time": "04:10", "type": "move", "x": 100, "y": 200},
  {"time": "04:35", "type": "act", "name": "jumping"},
  {"time": "04:55", "type": "speak", "text": "hi"}
]
''';
    final out = parsePetTimeline(raw);
    expect(out, hasLength(14));
  });

  test('tolerates a trailing comma before the (missing) ]', () {
    final raw = '''
[
  {"time": "00:05", "type": "act", "name": "waving"},
  {"time": "00:20", "type": "speak", "text": "hi"},
  {"time": "00:40", "type": "move", "x": 100, "y": 200, "speed": 60},
  {"time": "01:00", "type": "act", "name": "jumping"},
  {"time": "01:25", "type": "speak", "text": "hi"},
  {"time": "01:50", "type": "move", "x": 100, "y": 200},
  {"time": "02:15", "type": "act", "name": "failed"},
  {"time": "02:35", "type": "speak", "text": "hi"},
  {"time": "03:00", "type": "move", "x": 100, "y": 200},
  {"time": "03:25", "type": "act", "name": "waving"},
  {"time": "03:45", "type": "speak", "text": "hi"},
  {"time": "04:10", "type": "move", "x": 100, "y": 200},
  {"time": "04:35", "type": "act", "name": "jumping"},
  {"time": "04:55", "type": "speak", "text": "hi"},
''';
    final out = parsePetTimeline(raw);
    expect(out, hasLength(14));
  });

  test('tolerates prose after the JSON array', () {
    final raw = '''
[
  {"time": "00:05", "type": "act", "name": "waving"},
  {"time": "00:20", "type": "speak", "text": "hi"},
  {"time": "00:40", "type": "move", "x": 100, "y": 200, "speed": 60},
  {"time": "01:00", "type": "act", "name": "jumping"},
  {"time": "01:25", "type": "speak", "text": "hi"},
  {"time": "01:50", "type": "move", "x": 100, "y": 200},
  {"time": "02:15", "type": "act", "name": "failed"},
  {"time": "02:35", "type": "speak", "text": "hi"},
  {"time": "03:00", "type": "move", "x": 100, "y": 200},
  {"time": "03:25", "type": "act", "name": "waving"},
  {"time": "03:45", "type": "speak", "text": "hi"},
  {"time": "04:10", "type": "move", "x": 100, "y": 200},
  {"time": "04:35", "type": "act", "name": "jumping"},
  {"time": "04:55", "type": "speak", "text": "hi"}
]
Hope this works! Let me know if you need anything else.
''';
    final out = parsePetTimeline(raw);
    expect(out, hasLength(14));
  });
}
