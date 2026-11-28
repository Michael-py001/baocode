import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/guard.dart'
    show GuardListener, GuardProtocol, GuardSessionStatus;
import 'package:bao_remote/protocol.dart'
    show ChannelLink, ResumableChannel, RpcPeer;
import 'package:flutter_test/flutter_test.dart';

/// A reconnecting GUI reuses the live engine instead of rebuilding it: the
/// daemon answers session/open with reused:true and the engine does not emit
/// a fresh system/init (which a rebuilt engine would). Needs the compiled
/// guard beside the spawn service.
void main() {
  test(
    'reopening a live session reattaches without rebuilding the engine',
    () async {
      final exe = File(
        '${Directory.current.path}/windows/spawn_shim/baocode-guard.exe',
      );
      if (!Platform.isWindows || !exe.existsSync()) {
        // ignore: avoid_print
        print('skip: no compiled baocode-guard.exe');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('guard-reattach-');
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

      // One channel for the whole test: reconnect swaps only the socket so
      // ResumableChannel's counts stay valid (matching GuardClient).
      final channel = ResumableChannel();
      final peer = RpcPeer(channel.messages, channel.send);

      Future<Socket> link() async {
        final address = await GuardListener.readAddress(dir.path);
        expect(address, isNotNull);
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          address!.port,
        );
        socket.add(utf8.encode('${address.token}\n'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        unawaited(
          channel.attach(
            ChannelLink(
              input: socket,
              write: socket.add,
              close: socket.destroy,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return socket;
      }

      Future<Map<String, Object?>> openSession(String id) => peer
          .request(GuardProtocol.sessionOpen, {
            'options': {
              'cwd': Directory.current.path,
              'sessionId': id,
              'model': 'probe',
              'persist': true,
              'canAsk': false,
            },
          })
          .then((a) => a is Map ? a.cast<String, Object?>() : const {});

      var socket = await link();
      const id = 'reattach-probe';
      final first = await openSession(id);
      expect(first['reused'], false);

      // The first open constructs a fresh engine (reused:false). The engine
      // may need credentials to emit messages, so identity is proven below
      // via the reused flag and the interrupted marker, not via init counts.

      // Simulate a GUI crash: drop the socket, no session/close.
      socket.destroy();
      await Future<void>.delayed(const Duration(seconds: 1));

      // Reconnect and reopen the same id.
      socket = await link();
      final second = await openSession(id);
      expect(second['reused'], true);

      // Session state is still running, not interrupted: the rebuild path
      // (GuardSession.rebuild/_open with _rebuilds>0) would set interrupted.
      final listed = await peer.request(GuardProtocol.sessionList);
      final sessions =
          (listed is Map ? listed['sessions'] : null) as List? ?? [];
      final record = sessions.firstWhere(
        (s) => s is Map && s['id'] == id,
        orElse: () => <String, Object?>{},
      ) as Map;
      expect(record['status'], GuardSessionStatus.running.wireName);
      expect(record['interrupted'], false);

      peer.close();
      channel.close();
      socket.destroy();
    },
    timeout: const Timeout(Duration(seconds: 25)),
  );
}
