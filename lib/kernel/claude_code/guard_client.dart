// The app's side of the resident guard. One connection carries both session
// traffic (stream-json in both directions, control requests) and session
// management. The guard lives in its own process, so a GUI crash leaves the
// agent running and a fresh GUI attaches to the same socket.
import 'dart:async';
import 'dart:io';

import 'package:bao_remote/guard.dart'
    show GuardAddress, GuardListener, GuardProtocol;
import 'package:bao_remote/protocol.dart'
    show ChannelLink, ResumableChannel, RpcPeer;

/// The one client the app uses, so all sessions share a single connection
/// and a single reconnect loop. Data dir is set once at startup from the
/// resolved `DataDirectory.current.path`.
abstract final class GuardConnection {
  static GuardClient? _instance;
  static String? _dataDir;

  static void configure(String dataDir) {
    _dataDir = dataDir;
  }

  static GuardClient? get instance {
    final dir = _dataDir;
    if (dir == null) return null;
    return _instance ??= GuardClient(dir)..listen();
  }
}

/// Connects to the guard and exposes its session RPCs. Reconnects with a
/// simple backoff; `ResumableChannel` replays anything unacknowledged.
class GuardClient {
  GuardClient(this.dataDir, {void Function(String)? log})
    : log = log ?? ((_) {});

  final String dataDir;
  final void Function(String log) log;

  late final ResumableChannel channel = ResumableChannel(
    heartbeat: const Duration(seconds: 5),
    silence: const Duration(seconds: 45),
  );
  late final RpcPeer peer = RpcPeer(channel.messages, channel.send);

  Socket? _socket;
  Timer? _retry;
  int _backoffMs = 0;
  bool _closed = false;

  /// Stream-json messages from every session: `{sessionId, ...message}`.
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get messages => _messages.stream;

  /// Control requests the guard's engine needs answered: `{sessionId,
  /// requestId, request}`.
  final _controls = StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get controls => _controls.stream;

  /// Connects, or schedules a retry when no guard is listening yet.
  Future<void> connect() async {
    if (_closed) return;
    final connected = await _dial();
    if (!connected) {
      _scheduleRetry();
      return;
    }
    _backoffMs = 0;
  }

  Future<bool> _dial() async {
    try {
      final Socket socket;
      if (Platform.isWindows) {
        final address = await GuardListener.readAddress(dataDir);
        if (address == null) return false;
        socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          address.port,
          timeout: const Duration(seconds: 3),
        );
        // The guard's first line is the token.
        socket.write('${address.token}\n');
      } else {
        socket = await Socket.connect(
          InternetAddress(
            GuardAddress.socketPath(dataDir),
            type: InternetAddressType.unix,
          ),
          0,
          timeout: const Duration(seconds: 3),
        );
      }
      _socket = socket;
      unawaited(
        socket.done.then(
          (_) {
            if (identical(_socket, socket)) _lost();
          },
          onError: (Object _) {
            if (identical(_socket, socket)) _lost();
          },
        ),
      );
      // attach's future completes when the link is GONE, not when it is up;
      // awaiting it here would block connect() forever. Listen for "up"
      // first, then attach.
      final up = channel.linkChanges
          .firstWhere((up) => up)
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
      unawaited(
        channel.attach(
          ChannelLink(input: socket, write: socket.add, close: socket.destroy),
        ),
      );
      if (!await up) return false;
      return true;
    } on Object {
      return false;
    }
  }

  void _lost() {
    _socket = null;
    if (!_closed) _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    final delay = Duration(milliseconds: _backoffMs);
    _backoffMs = (_backoffMs == 0 ? 500 : _backoffMs * 2).clamp(0, 10000);
    _retry = Timer(delay, () => unawaited(connect()));
  }

  /// Registers handlers for the guard's notifications. Call once after
  /// construction, before [connect].
  void listen() {
    peer.notificationHandlers[GuardProtocol.sessionMessage] = (params) {
      if (params is Map) _messages.add(params.cast<String, Object?>());
    };
    peer.notificationHandlers[GuardProtocol.controlRequest] = (params) {
      if (params is Map) _controls.add(params.cast<String, Object?>());
    };
    unawaited(
      channel.ended.then((end) {
        log('guard channel ended: ${end.name}');
      }),
    );
  }

  Future<Map<String, Object?>> openSession(Map<String, Object?> options) async {
    final answer = await peer.request(GuardProtocol.sessionOpen, {
      'options': options,
    });
    return answer is Map ? answer.cast<String, Object?>() : const {};
  }

  Future<void> send(String sessionId, Map<String, Object?> message) => peer
      .request(GuardProtocol.sessionSend, {'id': sessionId, 'message': message})
      .then((_) {});

  /// Answers a control request the guard is waiting on.
  Future<void> answerControl(
    String sessionId,
    String requestId,
    Map<String, Object?> response,
  ) => peer
      .request(GuardProtocol.controlResponse, {
        'id': sessionId,
        'requestId': requestId,
        'response': response,
      })
      .then((_) {});

  Future<void> closeSession(String sessionId) =>
      peer.request(GuardProtocol.sessionClose, {'id': sessionId}).then((_) {});

  Future<List<Map<String, Object?>>> listSessions() async {
    final answer = await peer.request(GuardProtocol.sessionList);
    if (answer is! Map) return const [];
    final sessions = answer['sessions'];
    if (sessions is! List) return const [];
    return [
      for (final item in sessions)
        if (item is Map) item.cast<String, Object?>(),
    ];
  }

  /// Closes the connection. Pending RPCs fail with [RpcClosed].
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _socket?.close();
    _socket = null;
    peer.close();
    channel.close();
    await _messages.close();
    await _controls.close();
  }
}
