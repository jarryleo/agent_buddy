import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/sub_agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `subagent` tool's chat-bubble snapshot is the only thing
/// the user actually sees while a sub-agent runs. We want the
/// bubble to mirror the **report** (the summary the sub-agent is
/// composing for the main agent), not the messy list of the
/// sub-agent's intermediate tool calls. These tests pin down the
/// precedence rules in [ChatProvider.formatSubAgentSnapshot] so
/// we don't regress to the old "✓ fetch_web\n… search" display.
void main() {
  group('ChatProvider.formatSubAgentSnapshot', () {
    test('running with a partial report streams the report verbatim', () {
      // While the sub-agent is still running, the user should see
      // what the sub-agent is actually saying — even if the
      // report is incomplete. Tool calls should be ignored.
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.running,
        createdAt: DateTime(2026, 1, 1),
        report: 'TL;DR: the answer is 42.',
        toolCalls: const [
          SubAgentToolCall(
            id: 'tc-1',
            name: 'fetch_web',
            arguments: '{}',
            status: SubAgentToolStatus.success,
          ),
          SubAgentToolCall(
            id: 'tc-2',
            name: 'search',
            arguments: '{}',
            status: SubAgentToolStatus.running,
          ),
        ],
      );
      final snapshot = ChatProvider.formatSubAgentSnapshot(task);
      // The streaming report wins; tool calls / arrows must NOT
      // leak into the bubble.
      expect(snapshot, 'TL;DR: the answer is 42.');
      expect(snapshot, isNot(contains('fetch_web')));
      expect(snapshot, isNot(contains('search')));
      expect(snapshot, isNot(contains('✓')));
      expect(snapshot, isNot(contains('…')));
    });

    test('running without a report exposes no internal activity', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.running,
        createdAt: DateTime(2026, 1, 1),
        toolCalls: const [
          SubAgentToolCall(
            id: 'tc-1',
            name: 'fetch_web',
            arguments: '{}',
            status: SubAgentToolStatus.success,
          ),
          SubAgentToolCall(
            id: 'tc-2',
            name: 'search',
            arguments: '{}',
            status: SubAgentToolStatus.running,
          ),
        ],
      );
      final snapshot = ChatProvider.formatSubAgentSnapshot(task);
      expect(snapshot, isEmpty);
      expect(snapshot, isNot(contains('fetch_web')));
      expect(snapshot, isNot(contains('search')));
      expect(snapshot, isNot(contains('HTTP')));
    });

    test('running with no tool calls and no report is empty', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.running,
        createdAt: DateTime(2026, 1, 1),
      );
      final snapshot = ChatProvider.formatSubAgentSnapshot(task);
      expect(snapshot, isEmpty);
    });

    test('running with an empty report string is empty', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.running,
        createdAt: DateTime(2026, 1, 1),
        report: '',
        toolCalls: const [
          SubAgentToolCall(
            id: 'tc-1',
            name: 'current_time',
            arguments: '{}',
            status: SubAgentToolStatus.success,
          ),
        ],
      );
      final snapshot = ChatProvider.formatSubAgentSnapshot(task);
      expect(snapshot, isEmpty);
    });

    test('completed returns the final report', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.completed,
        createdAt: DateTime(2026, 1, 1),
        report: 'Final answer.',
      );
      expect(ChatProvider.formatSubAgentSnapshot(task), 'Final answer.');
    });

    test('completed with a null report shows the empty-report placeholder', () {
      // Defensive: a completed task with no report shouldn't
      // happen in practice (the runner would have flipped to
      // failed), but the snapshot must not crash.
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.completed,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        ChatProvider.formatSubAgentSnapshot(task),
        SubAgentService.noUsefulResult,
      );
    });

    test('failed hides the internal error message', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.failed,
        createdAt: DateTime(2026, 1, 1),
        error: 'HTTP 500',
      );
      final snapshot = ChatProvider.formatSubAgentSnapshot(task);
      expect(snapshot, SubAgentService.noUsefulResult);
      expect(snapshot, isNot(contains('HTTP 500')));
      expect(snapshot, isNot(startsWith('Error:')));
    });

    test('cancelled shows the cancelled marker', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: '',
        status: SubAgentStatus.cancelled,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        ChatProvider.formatSubAgentSnapshot(task),
        SubAgentService.cancelledResult,
      );
    });
  });

  group('ChatProvider.applyToolDoneEvent', () {
    test('keeps the sanitized terminal subagent snapshot', () {
      final finishedAt = DateTime(2026, 1, 1);
      final toolCall = ToolCall(
        id: 'sub-1',
        name: 'subagent',
        arguments: '{}',
        status: ToolCallStatus.failed,
        result: SubAgentService.noUsefulResult,
      );
      final event = StreamEvent.toolDone(
        id: 'sub-1',
        name: 'subagent',
        result: '{"tool_calls":[{"error":"HTTP 500"}]}',
        success: true,
        error: 'HTTP 500',
      );

      final merged = ChatProvider.applyToolDoneEvent(
        toolCall,
        event,
        finishedAt,
      );

      expect(merged.status, ToolCallStatus.failed);
      expect(merged.result, SubAgentService.noUsefulResult);
      expect(merged.result, isNot(contains('tool_calls')));
      expect(merged.result, isNot(contains('HTTP 500')));
      expect(merged.error, isNull);
      expect(merged.finishedAt, finishedAt);
    });
  });
}
