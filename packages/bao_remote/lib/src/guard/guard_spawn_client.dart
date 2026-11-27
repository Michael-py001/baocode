// Dart client for baocode-spawn.exe, the C++ service that owns every child
// process. Routing creation through that service is what keeps an injected
// DLL's CreateProcessW hook from aborting the app. See spawn_protocol.h for
// the wire format this file speaks.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'guard_protocol.dart';

/// What a process ran to: its exit code, and what it wrote.
typedef ProcessRun = ({int exitCode, Uint8List stdout, String stderr});

// Response frame types (spawn_protocol.h).
const int _stdout = 1;
const int _stderr = 2;
const int _exit = 3;
const int _failed = 4;

// Client frames after spawn (stdinMode 1).
const int _stdinWrite = 1;
const int _stdinClose = 2;

const int _flagRunInShell = 1 << 0;

const int _stdinNone = 0;
const int _stdinPipe = 1;

/// The `<port> <token>` the spawn service advertises, or null when it does not
/// run here. Mirrors [GuardListener.readAddress] but reads the service's own
/// address file.
Future<({int port, String token})?> _readAddress(String dataDir) async {
  if (!Platform.isWindows) return null;
  final file = File(GuardAddress.spawnPortPath(dataDir));
  if (!file.existsSync()) return null;
  final parts = file.readAsStringSync().trim().split(RegExp(r'\s+'));
  if (parts.length != 2) return null;
  final port = int.tryParse(parts[0]);
  if (port == null) return null;
  return (port: port, token: parts[1]);
}

/// Reads the length-prefixed `[u32 type][u32 length][bytes]` frames the
/// service sends, handing whole frames to [onFrame] as bytes arrive.
class _FrameReader {
  _FrameReader(this.socket, this.onFrame) {
    _subscription = socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  final Socket socket;
  final void Function(int type, Uint8List payload) onFrame;
  late final StreamSubscription<List<int>> _subscription;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();

  /// Completes when the connection closes (including on error).
  Future<void> get done => _done.future;

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    _drain();
  }

  void _drain() {
    while (true) {
      final bytes = _buffer.takeBytes();
      if (bytes.length < 8) {
        _buffer.add(bytes);
        return;
      }
      final view = ByteData.sublistView(bytes);
      final type = view.getUint32(0, Endian.little);
      final length = view.getUint32(4, Endian.little);
      if (bytes.length < 8 + length) {
        _buffer.add(bytes);
        return;
      }
      onFrame(type, Uint8List.sublistView(bytes, 8, 8 + length));
      if (bytes.length > 8 + length) {
        _buffer.add(Uint8List.sublistView(bytes, 8 + length));
      }
    }
  }

  void _onError(Object error, StackTrace stack) {
    if (!_done.isCompleted) _done.completeError(error, stack);
  }

  void _onDone() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() => _subscription.cancel();
}

/// A client of the C++ spawn service. On Windows all process creation goes
/// through the service; elsewhere [Process.start] is used directly (there is
/// no injected hook to dodge).
class SpawnClient {
  SpawnClient(this.dataDir);

  final String dataDir;

  /// Whether the spawn service is running and reachable at [dataDir].
  bool get available => _availableSync;

  bool get _availableSync =>
      Platform.isWindows &&
      File(GuardAddress.spawnPortPath(dataDir)).existsSync();

  /// Checks the spawn service's address file and that its port is listening.
  static Future<bool> isAvailable(String dataDir) async {
    final address = await _readAddress(dataDir);
    if (address == null) return false;
    try {
      final other = await Socket.connect(
        InternetAddress.loopbackIPv4,
        address.port,
        timeout: const Duration(seconds: 2),
      );
      other.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<({Socket socket, String? token})> _connect() async {
    if (!Platform.isWindows) {
      throw const ProcessException('spawn', [], 'Not on Windows');
    }
    final address = await _readAddress(dataDir);
    if (address == null) {
      throw ProcessException(
        'spawn',
        [],
        'No spawn service at ${GuardAddress.spawnPortPath(dataDir)}',
      );
    }
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      address.port,
      timeout: const Duration(seconds: 2),
    );
    return (socket: socket, token: address.token);
  }

  /// Runs a process to completion and returns what it wrote and its exit
  /// code. Past [timeout] the connection is destroyed and the run is reported
  /// as killed (exit code -1). A `failed` frame throws a [ProcessException].
  Future<ProcessRun> run({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    Map<String, String> environment = const {},
    bool runInShell = false,
    Uint8List? input,
    required Duration timeout,
  }) async {
    if (!Platform.isWindows) {
      return _runLocal(
        executable: executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: runInShell,
        input: input,
        timeout: timeout,
      );
    }
    final (socket: socket, token: token) = await _connect();
    final stdout = BytesBuilder(copy: false);
    final stderr = StringBuffer();
    final exit = Completer<int>();
    final frameReader = _FrameReader(socket, (type, payload) {
      switch (type) {
        case _stdout:
          stdout.add(payload);
        case _stderr:
          stderr.write(utf8.decode(payload, allowMalformed: true));
        case _exit:
          if (!exit.isCompleted) {
            exit.complete(
              ByteData.sublistView(payload).getInt32(0, Endian.little),
            );
          }
        case _failed:
          if (!exit.isCompleted) {
            final error = ByteData.sublistView(payload)
                .getUint32(0, Endian.little);
            exit.completeError(
              ProcessException(
                executable,
                arguments,
                'spawn failed: $error',
                error,
              ),
            );
          }
        case 5: // pid frame
        default:
          // pid and unknown frames carry nothing this call needs.
          break;
      }
    });
    unawaited(
      frameReader.done.then(
        (_) {
          if (!exit.isCompleted) exit.complete(-1);
        },
        onError: (Object error, StackTrace stack) {
          if (!exit.isCompleted) exit.completeError(error, stack);
        },
      ),
    );

    socket.add(utf8.encode('$token\n'));
    socket.add(
      _requestFrame(
        commandLine: _commandLine(
          executable,
          arguments,
          runInShell: runInShell,
        ),
        workingDirectory: workingDirectory,
        environment: environment,
        stdinMode: input == null ? _stdinNone : _stdinPipe,
        flags: runInShell ? _flagRunInShell : 0,
      ),
    );
    if (input != null) _writeStdin(socket, input, close: true);

    try {
      final code = await exit.future.timeout(
        timeout,
        onTimeout: () {
          socket.destroy();
          return -1;
        },
      );
      return (exitCode: code, stdout: stdout.takeBytes(), stderr: '$stderr');
    } finally {
      await frameReader.close();
      socket.destroy();
    }
  }

  /// Starts a process whose stdio stays open, for interactive clients (the
  /// Claude CLI, LSP and MCP). [stdin] writes bytes to the child and closes
  /// it; [exitCode] completes when the child exits or the service fails.
  Future<SpawnedProcess> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    Map<String, String> environment = const {},
    bool runInShell = false,
  }) async {
    if (!Platform.isWindows) {
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: runInShell,
      );
      return SpawnedProcess._local(process);
    }
    final (socket: socket, token: token) = await _connect();
    final stdout = StreamController<Uint8List>.broadcast();
    final stderr = StreamController<Uint8List>.broadcast();
    final exit = Completer<int>();
    final frameReader = _FrameReader(socket, (type, payload) {
      switch (type) {
        case _stdout:
          stdout.add(Uint8List.fromList(payload));
        case _stderr:
          stderr.add(Uint8List.fromList(payload));
        case _exit:
          if (!exit.isCompleted) {
            exit.complete(
              ByteData.sublistView(payload).getInt32(0, Endian.little),
            );
          }
        case _failed:
          final error = ByteData.sublistView(payload)
              .getUint32(0, Endian.little);
          final failure = ProcessException(
            executable,
            arguments,
            'spawn failed: $error',
            error,
          );
          if (!exit.isCompleted) exit.completeError(failure);
          stdout.addError(failure);
          stderr.addError(failure);
        default:
          // pid: nothing to expose here.
          break;
      }
    });
    unawaited(
      frameReader.done.then(
        (_) {
          if (!exit.isCompleted) exit.complete(-1);
          unawaited(stdout.close());
          unawaited(stderr.close());
        },
        onError: (Object error, StackTrace stack) {
          if (!exit.isCompleted) exit.completeError(error, stack);
          stdout.addError(error, stack);
          stderr.addError(error, stack);
          unawaited(stdout.close());
          unawaited(stderr.close());
        },
      ),
    );

    socket.add(utf8.encode('$token\n'));
    socket.add(
      _requestFrame(
        commandLine: _commandLine(
          executable,
          arguments,
          runInShell: runInShell,
        ),
        workingDirectory: workingDirectory,
        environment: environment,
        stdinMode: _stdinPipe,
        flags: runInShell ? _flagRunInShell : 0,
      ),
    );
    return SpawnedProcess._(
      stdout.stream,
      stderr.stream,
      exit.future,
      (data) => _writeStdin(socket, data),
      () {
        _writeStdin(socket, Uint8List(0), close: true);
        unawaited(socket.close());
      },
    );
  }

  void _writeStdin(Socket socket, Uint8List data, {bool close = false}) {
    final frame = BytesBuilder(copy: false)
      ..add(_u32(_stdinWrite))
      ..add(_u32(data.length))
      ..add(data);
    if (close) {
      frame
        ..add(_u32(_stdinClose))
        ..add(_u32(0));
    }
    socket.add(frame.takeBytes());
  }
}

/// A process started with [SpawnClient.start], with its stdio still open.
/// The streams are broadcast so more than one listener can read them.
final class SpawnedProcess {
  SpawnedProcess._(
    this.stdout,
    this.stderr,
    this.exitCode,
    void Function(Uint8List) write,
    void Function() close,
  ) : _write = write,
      _close = close;

  SpawnedProcess._local(Process process)
    : this._(
        process.stdout.map((bytes) => Uint8List.fromList(bytes)),
        process.stderr.map((bytes) => Uint8List.fromList(bytes)),
        process.exitCode,
        (data) => process.stdin.add(data),
        () => unawaited(process.stdin.close().catchError((Object _) {})),
      );

  final Stream<Uint8List> stdout;
  final Stream<Uint8List> stderr;
  final Future<int> exitCode;
  final void Function(Uint8List) _write;
  final void Function() _close;

  /// Writes bytes to the child's stdin.
  void write(Uint8List data) => _write(data);

  /// Closes the child's stdin.
  void close() => _close();
}

Uint8List _u32(int value) {
  final bytes = Uint8List(4);
  ByteData.view(bytes.buffer).setUint32(0, value, Endian.little);
  return bytes;
}

/// Builds the request frame: five u32 fields then the three UTF-16LE payloads.
Uint8List _requestFrame({
  required String commandLine,
  required String workingDirectory,
  required Map<String, String> environment,
  required int flags,
  required int stdinMode,
}) {
  final command = _utf16(commandLine);
  final cwd = _utf16(workingDirectory);
  final env = _environmentBlock(environment);
  final frame = BytesBuilder(copy: false)
    ..add(_u32(command.length))
    ..add(_u32(cwd.length))
    ..add(_u32(env.length))
    ..add(_u32(flags))
    ..add(_u32(stdinMode))
    ..add(command)
    ..add(cwd)
    ..add(env);
  return frame.takeBytes();
}

/// Encodes UTF-16LE without a BOM: `codeUnits` are already UTF-16 code units,
/// so writing them little-endian is all CreateProcessW's block needs.
Uint8List _utf16(String value) {
  final units = value.codeUnits;
  final bytes = Uint8List(units.length * 2);
  final view = ByteData.view(bytes.buffer);
  for (var i = 0; i < units.length; i++) {
    view.setUint16(i * 2, units[i], Endian.little);
  }
  return bytes;
}

/// A double-null-terminated UTF-16LE block of `KEY=VALUE` strings, or empty
/// for "inherit the service's environment".
Uint8List _environmentBlock(Map<String, String> environment) {
  if (environment.isEmpty) return Uint8List(0);
  final buffer = StringBuffer();
  for (final entry in environment.entries) {
    buffer.write('${entry.key}=${entry.value}\u0000');
  }
  buffer.write('\u0000');
  return _utf16(buffer.toString());
}

/// Windows command line for one argument, quoted the way CommandLineToArgvW
/// reads it: wrap arguments containing whitespace or quotes, and double the
/// backslashes that precede a quote (or the closing quote).
String _quoteArgument(String argument) {
  final needsQuotes = argument.isEmpty || argument.contains(RegExp(r'[\s"]'));
  final buffer = StringBuffer(needsQuotes ? '"' : '');
  var backslashes = 0;
  for (final rune in argument.runes) {
    if (rune == 0x5C) {
      backslashes++;
      continue;
    }
    if (rune == 0x22) {
      buffer.write('\\' * (backslashes * 2 + 1));
      buffer.write('"');
    } else {
      buffer.write('\\' * backslashes);
      buffer.writeCharCode(rune);
    }
    backslashes = 0;
  }
  if (needsQuotes) {
    buffer.write('\\' * (backslashes * 2));
    buffer.write('"');
  } else {
    buffer.write('\\' * backslashes);
  }
  return '$buffer';
}

String _commandLine(
  String executable,
  List<String> arguments, {
  required bool runInShell,
}) => [
  if (runInShell) 'cmd.exe',
  if (runInShell) '/c',
  _quoteArgument(executable),
  for (final argument in arguments) _quoteArgument(argument),
].join(' ');

Future<ProcessRun> _runLocal({
  required String executable,
  required List<String> arguments,
  required String workingDirectory,
  required Map<String, String> environment,
  required bool runInShell,
  Uint8List? input,
  required Duration timeout,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: runInShell,
  );
  final stdout = BytesBuilder(copy: false);
  final stderr = StringBuffer();
  final reading = Future.wait([
    process.stdout.listen(stdout.add).asFuture<void>(),
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderr.write)
        .asFuture<void>(),
  ]);
  unawaited(process.stdin.done.catchError((Object _) {}));
  if (input != null) process.stdin.add(input);
  unawaited(process.stdin.close().catchError((Object _) {}));
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  await reading;
  return (exitCode: code, stdout: stdout.takeBytes(), stderr: '$stderr');
}

/// Starts baocode-spawn.exe as a detached service at [dataDir] and writes the
/// `<port> <token>` file the [SpawnClient] reads. Picks a free loopback port;
/// returns the process so the caller can keep or kill it.
Future<Process> startSpawnService(
  String dataDir, {
  required String executable,
}) async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  final token = _hexToken();
  final process = await Process.start(executable, [
    '--port',
    '$port',
    '--token',
    token,
  ], mode: ProcessStartMode.detached);
  final file = File(GuardAddress.spawnPortPath(dataDir));
  await file.parent.create(recursive: true);
  await file.writeAsString('$port $token', flush: true);
  return process;
}

String _hexToken() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
