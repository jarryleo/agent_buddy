import 'package:agent_buddy/models/local_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalProvider.thinkingBudgetTokens', () {
    LocalProvider make({int? thinkingBudgetTokens, int batchSize = 512}) {
      return LocalProvider(
        id: 'p1',
        name: 'test',
        modelPath: '/tmp/model.gguf',
        batchSize: batchSize,
        thinkingBudgetTokens: thinkingBudgetTokens,
      );
    }

    test('defaults to null (no budget) when not supplied', () {
      // The legacy behavior must survive: a provider created via
      // the old constructor signature should not suddenly gain a
      // 2K reasoning budget because the field was added later.
      final p = LocalProvider(
        id: 'p1',
        name: 'test',
        modelPath: '/tmp/model.gguf',
      );
      expect(p.thinkingBudgetTokens, isNull);
    });

    test('preserves an explicit positive value', () {
      expect(make(thinkingBudgetTokens: 4096).thinkingBudgetTokens, 4096);
    });

    test('preserves an explicit null (no budget)', () {
      expect(make(thinkingBudgetTokens: null).thinkingBudgetTokens, isNull);
    });

    test('toJson round-trips a positive budget', () {
      final p = make(thinkingBudgetTokens: 2048);
      final restored = LocalProvider.fromJson(p.toJson());
      expect(restored.thinkingBudgetTokens, 2048);
    });

    test('toJson round-trips a null budget (no cap)', () {
      final p = make(thinkingBudgetTokens: null);
      final restored = LocalProvider.fromJson(p.toJson());
      expect(restored.thinkingBudgetTokens, isNull);
    });

    test('fromJson coerces 0 and negatives to null (no cap)', () {
      // llama.cpp accepts 0 as "no budget" but our JSON contract
      // uses `null` to express that — keeps the wire format clean
      // and avoids a placeholder "0 tokens of reasoning" read.
      final p = LocalProvider.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'test',
        'modelPath': '/tmp/model.gguf',
        'batchSize': 512,
        'thinkingBudgetTokens': 0,
      });
      expect(p.thinkingBudgetTokens, isNull);

      final pNeg = LocalProvider.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'test',
        'modelPath': '/tmp/model.gguf',
        'batchSize': 512,
        'thinkingBudgetTokens': -7,
      });
      expect(pNeg.thinkingBudgetTokens, isNull);
    });

    test('fromJson treats missing field as null (older configs)', () {
      // Backwards compatibility: rows written before this field
      // existed must continue to deserialize as "no budget".
      final p = LocalProvider.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'test',
        'modelPath': '/tmp/model.gguf',
        'batchSize': 512,
      });
      expect(p.thinkingBudgetTokens, isNull);
    });

    test('fromRawJson round-trip preserves the budget', () {
      final p = make(thinkingBudgetTokens: 8192);
      final restored = LocalProvider.fromRawJson(p.toRawJson());
      expect(restored.thinkingBudgetTokens, 8192);
    });

    test(
      'copyWith leaves the budget untouched when the argument is omitted',
      () {
        final p = make(thinkingBudgetTokens: 1024);
        // Common "edit one field" path: copyWith(name: 'foo') must
        // keep the budget intact. Without the sentinel pattern, the
        // nullable field would always be overwritten to null.
        final p2 = p.copyWith(name: 'foo');
        expect(p2.thinkingBudgetTokens, 1024);
        expect(p2.name, 'foo');
      },
    );

    test('copyWith can clear the budget by passing null', () {
      // Equally important: the user must be able to switch back
      // to "no cap" by editing the form. The sentinel pattern
      // distinguishes "argument omitted" from "argument = null".
      final p = make(thinkingBudgetTokens: 1024);
      final p2 = p.copyWith(thinkingBudgetTokens: null);
      expect(p2.thinkingBudgetTokens, isNull);
    });

    test('copyWith can set a new positive budget', () {
      final p = make(thinkingBudgetTokens: 1024);
      final p2 = p.copyWith(thinkingBudgetTokens: 4096);
      expect(p2.thinkingBudgetTokens, 4096);
    });
  });

  group('LocalProvider.thinkingBudgetChipLabel', () {
    LocalProvider withBudget(int? tokens) => LocalProvider(
      id: 'p1',
      name: 'test',
      modelPath: '/tmp/model.gguf',
      thinkingBudgetTokens: tokens,
    );

    test('null budget renders as the no-cap sentinel', () {
      // The chip on the providers tab uses this to decide between
      // "思考 ∞" (no cap) and "思考 2K" (capped). The sentinel must
      // not accidentally render as "思考 0" or "思考 null" — those
      // would look like a real (zero / broken) budget.
      expect(withBudget(null).thinkingBudgetChipLabel, '∞');
    });

    test('zero budget also renders as the no-cap sentinel', () {
      // The 0 sentinel pre-dates this field (it was the wire-format
      // for "no cap" before the user could explicitly clear it).
      expect(withBudget(0).thinkingBudgetChipLabel, '∞');
    });

    test('power-of-two presets are abbreviated to K-suffix form', () {
      // Matches the visual style of the other _ParamChip rows
      // (e.g. `ctx 8192` is fine but `think 8K` is more scannable
      // in a 6-chip wrap).
      expect(withBudget(1024).thinkingBudgetChipLabel, '1K');
      expect(withBudget(2048).thinkingBudgetChipLabel, '2K');
      expect(withBudget(4096).thinkingBudgetChipLabel, '4K');
      expect(withBudget(8192).thinkingBudgetChipLabel, '8K');
      expect(withBudget(16384).thinkingBudgetChipLabel, '16K');
      expect(withBudget(32768).thinkingBudgetChipLabel, '32K');
    });

    test('non-power-of-two budgets are shown verbatim', () {
      // A user might type a custom value (e.g. 1500) — show it
      // exactly so they can see what they entered, instead of
      // silently rounding to a preset.
      expect(withBudget(1500).thinkingBudgetChipLabel, '1500');
      expect(withBudget(3000).thinkingBudgetChipLabel, '3000');
    });
  });
}
