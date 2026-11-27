import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/guard.dart' show GuardListener, GuardProtocol;
import 'package:bao_remote/protocol.dart'
    show ChannelLink, ResumableChannel, RpcPeer;
import 'package:flutter_test/flutter_test.dart';

/// A real compiled guard answers session RPCs over its socket, and the token
/// gate keeps a stranger out. Needs `baocode-guard.exe` built beside the
/// spawn service (the Windows build does this); skipped otherwise.
void main() {
  test('guard daemon answers session/list over its socket', () async {
    final exe = File(
      '${Directory.current.path}/windows/spawn_shim/baocode-guard.exe',
    );
    if (!Platform.isWindows || !exe.existsSync()) {
      // ignore: avoid_print
      print('skip: no compiled baocode-guard.exe');
      return;
    }

    final dir = Directory.systemTemp.createTempSync('guard-e2e-');
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

    expect(await GuardListener.isListening(dir.path), isTrue);
    final address = await GuardListener.readAddress(dir.path);
    expect(address, isNotNull);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      address!.port,
    );
    socket.add(utf8.encode('${address.token}\n'));
    final channel = ResumableChannel();
    final peer = RpcPeer(channel.messages, channel.send);
    unawaited(
      channel.attach(
        ChannelLink(input: socket, write: socket.add, close: socket.destroy),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final answer = await peer.request(GuardProtocol.sessionList);
    expect(answer, isA<Map>());
    expect((answer as Map)['sessions'], isA<List>());

    peer.close();
    channel.close();
    socket.destroy();
  }, timeout: const Timeout(Duration(seconds: 20)));
}
