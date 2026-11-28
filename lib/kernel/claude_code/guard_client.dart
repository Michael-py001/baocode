// The app's side of the resident guard. One connection carries both session
// traffic (stream-json in both directions, control requests) and session
// management. The guard lives in its own process, so a GUI crash leaves the
// agent running and a fresh GUI attaches to the same socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show newUuid;
import 'package:bao_remote/guard.dart'
    show GuardAddress, GuardListener, GuardProtocol, SpawnClient;
import 'package:bao_remote/protocol.dart'
    show ChannelLink, ResumableChannel, RpcPeer;

import 'guard_process.dart' show GuardProcess, GuardRunResult, GuardStdin;

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

  /// Live child processes, keyed by the id sent with process/start.
  final _processes = <String, _ProcessStreams>{};

  /// Registers handlers for the guard's notifications. Call once after
  /// construction, before [connect].
  void listen() {
    peer.notificationHandlers[GuardProtocol.sessionMessage] = (params) {
      if (params is Map) _messages.add(params.cast<String, Object?>());
    };
    peer.notificationHandlers[GuardProtocol.controlRequest] = (params) {
      if (params is Map) _controls.add(params.cast<String, Object?>());
    };
    peer.notificationHandlers[GuardProtocol.processOutput] = (params) {
      if (params is! Map) return;
      final streams = _processes['${params['id']}'];
      if (streams == null) return;
      final out = _decodeBytes(params['stdout']);
      final err = _decodeBytes(params['stderr']);
      if (out.isNotEmpty) streams.stdout.add(out);
      if (err.isNotEmpty) streams.stderr.add(err);
    };
    peer.notificationHandlers[GuardProtocol.processExit] = (params) {
      if (params is! Map) return;
      final streams = _processes.remove('${params['id']}');
      streams?.finish(_intOf(params['exitCode']) ?? -1);
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

  /// Whether the guard's spawn service is available. Callers fall back to a
  /// local Process.start when it is not (e.g. early startup, no DLL).
  Future<bool> isAvailable() => SpawnClient.isAvailable(dataDir);

  /// Runs a child in the guard and returns what it wrote. Same shape as the
  /// guard's SpawnClient.run, carried over RPC so the GUI never spawns.
  Future<GuardRunResult> runProcess({
    required String executable,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool runInShell = false,
    bool includeParentEnvironment = false,
    Uint8List? input,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final answer = await peer.request(GuardProtocol.processRun, {
      'executable': executable,
      'arguments': arguments,
      'workingDirectory': ?workingDirectory,
      'environment': environment,
      'runInShell': runInShell,
      'includeParentEnvironment': includeParentEnvironment,
      'input': input == null ? null : base64Encode(input),
      'timeoutMs': timeout.inMilliseconds,
    });
    final map = answer is Map ? answer.cast<String, Object?>() : const {};
    return GuardRunResult(
      _intOf(map['exitCode']) ?? -1,
      _decodeBytes(map['stdout']),
      '${map['stderr'] ?? ''}',
      _intOf(map['pid']) ?? 0,
    );
  }

  /// Starts a child in the guard with its stdio still open. The returned
  /// object has the pid/stdin/stdout/stderr/kill shape callers expect.
  Future<GuardProcess> startProcess({
    required String executable,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool runInShell = false,
    bool includeParentEnvironment = false,
  }) async {
    final id = newUuid();
    final answer = await peer.request(GuardProtocol.processStart, {
      'id': id,
      'executable': executable,
      'arguments': arguments,
      'workingDirectory': ?workingDirectory,
      'environment': environment,
      'runInShell': runInShell,
      'includeParentEnvironment': includeParentEnvironment,
    });
    final map = answer is Map ? answer.cast<String, Object?>() : const {};
    final pid = _intOf(map['pid']) ?? 0;
    final streams = _ProcessStreams();
    _processes[id] = streams;
    return GuardProcess(
      this,
      id,
      pid,
      streams.stdout.stream,
      streams.stderr.stream,
      streams.exit.future,
      GuardStdin(this, id),
    );
  }

  Future<void> writeProcessStdin(
    String id,
    Uint8List data, {
    bool close = false,
  }) => peer
      .request(GuardProtocol.processStdin, {
        'id': id,
        'data': base64Encode(data),
        'close': close,
      })
      .then((_) {});

  Future<bool> killProcess(String id) async {
    final answer = await peer.request(GuardProtocol.processKill, {'id': id});
    return answer is Map && answer['ok'] == true;
  }

  /// Starts a child that outlives the app, through the guard's spawn service.
  Future<int> startDetachedProcess(
    String executable,
    List<String> arguments,
  ) async {
    final answer = await peer.request(GuardProtocol.processDetached, {
      'executable': executable,
      'arguments': arguments,
    });
    return answer is Map ? _intOf(answer['pid']) ?? -1 : -1;
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

/// The streams a live guard process feeds from process/output notifications.
class _ProcessStreams {
  final stdout = StreamController<Uint8List>.broadcast();
  final stderr = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();

  void finish(int code) {
    if (!exit.isCompleted) exit.complete(code);
    unawaited(stdout.close());
    unawaited(stderr.close());
  }
}

Uint8List _decodeBytes(Object? value) {
  if (value is! String) return Uint8List(0);
  try {
    return base64Decode(value);
  } on FormatException {
    return Uint8List(0);
  }
}

int? _intOf(Object? value) => value is int ? value : int.tryParse('$value');
