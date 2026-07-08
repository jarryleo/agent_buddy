import 'package:agent_buddy/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ApiService constructs', () {
    final api = ApiService();
    expect(api, isNotNull);
  });
}
