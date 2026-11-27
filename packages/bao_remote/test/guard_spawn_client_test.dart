// A fake C++ spawn service on loopback: it writes <port> <token> to the
// spawn address file and speaks spawn_protocol.h, so these tests exercise the
// real socket path without spawning anything. Run with `dart run` on Windows.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_remote/src/guard/guard_protocol.dart';
import 'package:bao_remote/src/guard/guard_spawn_client.dart';

void main() async {
  if (!Platform.isWindows) {
    // The service and the Dart client both require Windows; elsewhere the
    // client uses Process.start directly (no injected hook to dodge).
    print('skip: spawn client requires Windows');
    return;
  }

  var failures = 0;
  Future<void> test(String name, Future<void> Function() body) async {
    try {
      await body();
      print('ok - $name');
    } catch (error, stack) {
      failures++;
      print('FAIL - $name\n  $error\n$stack');
    }
  }

  void check(bool condition, Object message) {
    if (!condition) throw StateError('$message');
  }

  late Directory dataDir;
  late ServerSocket server;
  late Completer<Uint8List> requests;
  final token = 'tok-${DateTime.now().microsecondsSinceEpoch}';

  Future<void> setUp() async {
    dataDir = await Directory.systemTemp.createTemp('spawn-client-test');
    requests = Completer<Uint8List>();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final file = File(GuardAddress.spawnPortPath(dataDir.path));
    await file.parent.create(recursive: true);
    await file.writeAsString('${server.port} $token');
  }

  Future<void> tearDown() async {
    await server.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  }

  /// Serves one connection: reads the token line and request frame, captures
  /// the raw frame for assertions, then writes [out] as response frames.
  void serveOnce(List<(int, List<int>)> out) {
    server.listen((socket) async {
      final buffered = BytesBuilder(copy: false);
      var tokenRead = false;
      await for (final chunk in socket) {
        buffered.add(chunk);
        while (true) {
          final all = buffered.takeBytes();
          var offset = 0;
          if (!tokenRead) {
            final newline = all.indexOf(0x0A);
            if (newline < 0) {
              buffered.add(all);
              break;
            }
            check(
              utf8.decode(all.sublist(0, newline)).trim() == token,
              'token mismatch',
            );
            tokenRead = true;
            offset = newline + 1;
          }
          if (all.length - offset < 20) {
            buffered.add(Uint8List.sublistView(all, offset));
            break;
          }
          final cmdBytes = u32(all, offset);
          final cwdBytes = u32(all, offset + 4);
          final envBytes = u32(all, offset + 8);
          final length = 20 + cmdBytes + cwdBytes + envBytes;
          if (all.length - offset < length) {
            buffered.add(Uint8List.sublistView(all, offset));
            break;
          }
          final frame = Uint8List.sublistView(all, offset, offset + length);
          if (!requests.isCompleted) {
            requests.complete(Uint8List.fromList(frame));
          }
          for (final (type, bytes) in out) {
            socket.add(frameOf(type, bytes));
          }
          await socket.close();
          return;
        }
      }
    });
  }

  await test(
    'request frame layout: five u32 fields then UTF-16LE payloads',
    () async {
      await setUp();
      serveOnce([(3, int32(0))]);
      final run = await SpawnClient(dataDir.path).run(
        executable: 'echo.exe',
        arguments: ['hello world', 'a"b'],
        workingDirectory: 'C:\\work',
        environment: {'KEY': 'VALUE'},
        timeout: const Duration(seconds: 5),
      );
      check(run.exitCode == 0, 'exit 0');

      final frame = await requests.future;
      final cmdBytes = u32(frame, 0);
      final cwdBytes = u32(frame, 4);
      final envBytes = u32(frame, 8);
      check(u32(frame, 12) == 0, 'flags 0');
      check(u32(frame, 16) == 0, 'stdinMode 0');
      check(
        frame.length == 20 + cmdBytes + cwdBytes + envBytes,
        'frame length',
      );

      final commandLine = utf16(
        Uint8List.sublistView(frame, 20, 20 + cmdBytes),
      );
      final cwd = utf16(
        Uint8List.sublistView(frame, 20 + cmdBytes, 20 + cmdBytes + cwdBytes),
      );
      final env = utf16(
        Uint8List.sublistView(
          frame,
          20 + cmdBytes + cwdBytes,
          20 + cmdBytes + cwdBytes + envBytes,
        ),
      );
      check(
        commandLine == 'echo.exe "hello world" "a\\"b"',
        'commandLine: $commandLine',
      );
      check(cwd == 'C:\\work', 'cwd: $cwd');
      check(env == 'KEY=VALUE\u0000\u0000', 'env: ${env.codeUnits}');
      await tearDown();
    },
  );

  await test(
    'response frames: stdout bytes and stderr text accumulate',
    () async {
      await setUp();
      serveOnce([
        (1, utf8.encode('out')),
        (2, utf8.encode('err')),
        (5, int32(1234)), // pid
        (3, int32(7)),
      ]);
      final run = await SpawnClient(dataDir.path).run(
        executable: 'tool.exe',
        arguments: const [],
        workingDirectory: 'C:\\',
        timeout: const Duration(seconds: 5),
      );
      check(run.exitCode == 7, 'exit 7');
      check(utf8.decode(run.stdout) == 'out', 'stdout out');
      check(run.stderr == 'err', 'stderr err');
      await tearDown();
    },
  );

  await test('failed frame throws ProcessException', () async {
    await setUp();
    serveOnce([(4, int32(5))]); // Win32 ERROR_ACCESS_DENIED / hook threw.
    try {
      await SpawnClient(dataDir.path).run(
        executable: 'bad.exe',
        arguments: const [],
        workingDirectory: 'C:\\',
        timeout: const Duration(seconds: 5),
      );
      throw StateError('expected ProcessException');
    } on ProcessException catch (error) {
      check(error.errorCode == 5, 'errorCode 5, got ${error.errorCode}');
    }
    await tearDown();
  });

  await test('runInShell and input set flags and stdinMode', () async {
    await setUp();
    serveOnce([(3, int32(0))]);
    await SpawnClient(dataDir.path).run(
      executable: 'a.exe',
      arguments: const [],
      workingDirectory: 'C:\\',
      runInShell: true,
      input: Uint8List.fromList(utf8.encode('hi')),
      timeout: const Duration(seconds: 5),
    );
    final frame = await requests.future;
    check(u32(frame, 12) == 1, 'flag runInShell');
    check(u32(frame, 16) == 1, 'stdinMode pipe');
    await tearDown();
  });

  await test('isAvailable checks the port is listening', () async {
    await setUp();
    check(await SpawnClient.isAvailable(dataDir.path), 'available');
    await server.close();
    check(!await SpawnClient.isAvailable(dataDir.path), 'not available');
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  if (failures > 0) {
    throw StateError('$failures test(s) failed');
  }
}

Uint8List frameOf(int type, List<int> payload) {
  final builder = BytesBuilder(copy: false)
    ..add(u32Bytes(type))
    ..add(u32Bytes(payload.length))
    ..add(payload);
  return builder.takeBytes();
}

Uint8List u32Bytes(int value) {
  final bytes = Uint8List(4);
  ByteData.view(bytes.buffer).setUint32(0, value, Endian.little);
  return bytes;
}

int u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

Uint8List int32(int value) {
  final bytes = Uint8List(4);
  ByteData.view(bytes.buffer).setInt32(0, value, Endian.little);
  return bytes;
}

String utf16(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}
