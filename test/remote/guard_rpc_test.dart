import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/guard.dart' show GuardListener, GuardProtocol;
import 'package:bao_remote/protocol.dart'
    show ChannelLink, ResumableChannel, RpcPeer;
import 'package:flutter_test/flutter_test.dart';

/// The guard's process/run RPC really spawns through the SEH-guarded C++
/// service and returns a live pid, bytes and exit code. Needs the compiled
/// guard next to the spawn service (the Windows build does this).
void main() {
  test(
    'process/run RPC spawns a child and reports pid, output, exit',
    () async {
      final exe = File(
        '${Directory.current.path}/windows/spawn_shim/baocode-guard.exe',
      );
      if (!Platform.isWindows || !exe.existsSync()) {
        // ignore: avoid_print
        print('skip: no compiled baocode-guard.exe');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('guard-rpc-');
      final guard = await Process.start(exe.path, ['--data', dir.path]);
      addTearDown(() {
        guard.kill();
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Gone already.
        }
      });
      await Future<void>.delayed(const Duration(seconds: 2));

      final channel = ResumableChannel();
      final peer = RpcPeer(channel.messages, channel.send);
      final address = await GuardListener.readAddress(dir.path);
      expect(address, isNotNull);
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        address!.port,
      );
      socket.add(utf8.encode('${address.token}\n'));
      unawaited(
        channel.attach(
          ChannelLink(input: socket, write: socket.add, close: socket.destroy),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final answer = await peer.request(GuardProtocol.processRun, {
        'executable': 'cmd.exe',
        'arguments': ['/c', 'echo guarded-rpc & exit 7'],
        'workingDirectory': 'C:\\Windows',
        'environment': {},
        'runInShell': false,
        'timeoutMs': 10000,
      });
      final map = answer as Map;
      final out = String.fromCharCodes(base64Decode('${map['stdout']}'));
      expect(map['exitCode'], 7);
      expect(map['pid'], greaterThan(0));
      expect(out, contains('guarded-rpc'));

      peer.close();
      channel.close();
      socket.destroy();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
