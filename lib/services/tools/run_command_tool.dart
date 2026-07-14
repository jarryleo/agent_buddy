import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../tool_service.dart';
import 'tool_base.dart';

class RunCommandTool extends ToolBase {
  @override
  String get id => 'run_command';
  @override
  String get name => '命令行执行';
  @override
  String get description => '在电脑上执行命令,返回输出结果和退出码。仅 Windows / macOS / Linux 可用。';
  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'run_command',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': '要执行的命令(通过系统 shell 运行)',
            },
            'cwd': {'type': 'string', 'description': '工作目录,可选,默认当前'},
            'timeout_seconds': {
              'type': 'integer',
              'description': '超时秒数,默认 30,超时自动杀掉',
              'default': 30,
              'minimum': 1,
              'maximum': 600,
            },
          },
          'required': ['command'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    if (kIsWeb) {
      throw ToolException('run_command is not supported on web');
    }
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw ToolException(
        'run_command is only supported on desktop (macOS / Windows / Linux)',
      );
    }
    final command = (args['command'] as String? ?? '').trim();
    if (command.isEmpty) {
      throw ToolException('command must not be empty');
    }
    final cwd = args['cwd'] as String?;
    final timeoutSeconds = (args['timeout_seconds'] as num?)?.toInt() ?? 30;

    final Process process;
    try {
      process = await Process.start(
        command,
        const [],
        workingDirectory: cwd,
        runInShell: true,
      );
    } catch (e) {
      throw ToolException('failed to start command: $e');
    }

    final decoder = systemEncoding.decoder;
    final stdoutFuture = process.stdout.transform(decoder).toList();
    final stderrFuture = process.stderr.transform(decoder).toList();

    final exitCode = await process.exitCode.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        process.kill();
        throw TimeoutException('command timed out after ${timeoutSeconds}s');
      },
    );

    final stdout = (await stdoutFuture).join();
    final stderr = (await stderrFuture).join();

    final payload = jsonEncode({
      'exit_code': exitCode,
      'stdout': stdout,
      'stderr': stderr,
    });
    if (exitCode != 0) {
      throw ToolException(payload);
    }
    return payload;
  }
}
