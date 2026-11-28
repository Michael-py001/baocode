// A child process owned by the guard, seen from the app. It has the shape
// callers already use from dart:io Process (pid, stdin/stdout/stderr, kill),
// but every operation is an RPC over the guard socket: the actual
// CreateProcessW happens in the SEH-guarded spawn service, never here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'guard_client.dart' show GuardClient, GuardConnection;

class GuardProcess {
  GuardProcess(
    this._client,
    this.id,
    this.pid,
    this.stdout,
    this.stderr,
    this.exitCode,
    this.stdin,
  );

  final GuardClient _client;
  final String id;
  final int pid;
  final Stream<Uint8List> stdout;
  final Stream<Uint8List> stderr;
  final Future<int> exitCode;
  final GuardStdin stdin;

  /// Accepts an optional signal to match dart:io Process.kill's signature;
  /// the guard's service terminates the child either way.
  Future<bool> kill([Object? signal]) => _client.killProcess(id);

  /// Closes the child's stdin (matches dart:io Process.close's teardown use).
  Future<void> close() => stdin.close();
}

/// The bytes a guard-run command wrote and its exit code/pid.
class GuardRunResult {
  const GuardRunResult(this.exitCode, this.stdout, this.stderr, this.pid);

  final int exitCode;
  final Uint8List stdout;
  final String stderr;
  final int pid;
}

/// The stdin of a guard process: only the operations callers use, each an
/// RPC. [writeln] is here because the Claude CLI transport uses it.
class GuardStdin {
  GuardStdin(this._client, this._id);

  final GuardClient _client;
  final String _id;
  bool _closed = false;

  void add(List<int> data) {
    if (!_closed) {
      unawaited(_client.writeProcessStdin(_id, Uint8List.fromList(data)));
    }
  }

  void writeln([Object? object = '']) {
    add('$object\n'.codeUnits);
  }

  void write(Object? object) => add('$object'.codeUnits);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _client.writeProcessStdin(_id, Uint8List(0), close: true);
  }
}

/// Runs [executable] the guarded way when the guard is up, else with the
/// plain dart:io Process.run. Returns a ProcessResult-compatible shape: the
/// fields callers read are exitCode/stdout/stderr; pid is added for the
/// taskkill paths.
Future<GuardRunResult> runGuarded(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool runInShell = false,
  bool includeParentEnvironment = false,
  Encoding stderrEncoding = utf8,
  Duration timeout = const Duration(seconds: 30),
  Uint8List? input,
}) async {
  final client = GuardConnection.instance;
  if (client != null && await client.isAvailable()) {
    try {
      return await client.runProcess(
        executable: executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment ?? const {},
        runInShell: runInShell,
        includeParentEnvironment: includeParentEnvironment,
        input: input,
        timeout: timeout,
      );
    } on Object {
      // The guard went away mid-request: fall through to a local run.
    }
  }
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    // null encodings make dart:io hand back raw bytes, matching the guard
    // path's Uint8List stdout (Process.run's defaults would be Strings).
    stdoutEncoding: null,
    stderrEncoding: null,
  ).timeout(timeout);
  return GuardRunResult(
    result.exitCode,
    Uint8List.fromList(result.stdout as List<int>),
    stderrEncoding.decode(result.stderr as List<int>),
    -1,
  );
}
