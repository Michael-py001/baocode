// A ClaudeCodeTransport backed by a session in the resident guard instead of
// an in-process isolate. The engine runs in the guard process, so the GUI can
// die and restart without losing the turn; this transport just relays the
// stream-json messages over the guard's IPC.
import 'dart:async';

import 'package:bao_remote/guard.dart' show GuardProtocol;

import 'claude_code_transport.dart'
    show ClaudeCodeTransport, ClaudeExit, ClaudeLaunch;
import 'guard_client.dart' show GuardClient;
import 'guard_options.dart' show guardEngineOptions;

class GuardTransport implements ClaudeCodeTransport {
  GuardTransport._(this._client, this.sessionId);

  final GuardClient _client;
  final String sessionId;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final _exited = Completer<void>();

  static Future<ClaudeCodeTransport> start(
    GuardClient client,
    ClaudeLaunch launch,
  ) async {
    final options = await guardEngineOptions(launch);
    final answer = await client.openSession(options);
    final id = '${answer['id'] ?? ''}';
    final transport = GuardTransport._(client, id);
    transport._subscription = client.messages
        .where((message) => message['sessionId'] == id)
        .listen(
          transport._onMessage,
          onError: transport._finish,
          onDone: transport._finish,
        );
    return transport;
  }

  void _onMessage(Map<String, Object?> message) {
    if (message['type'] == GuardProtocol.controlRequest) {
      // The engine asked the host (us) for a permission decision; relay it
      // to the kernel as an ordinary control_request and let it answer via
      // write(). The guard holds the request until it sees the response.
      _messages.add({
        'type': 'control_request',
        'request_id': message['requestId'],
        'request': message['request'],
      });
      return;
    }
    _messages.add(message);
  }

  void _finish([Object? _]) {
    if (!_messages.isClosed) {
      _messages.add(ClaudeExit.message(0, '', executable: 'bao-guard'));
      _messages.close();
    }
    if (!_exited.isCompleted) _exited.complete();
  }

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void write(Map<String, Object?> message) {
    if (message['type'] == 'control_response') {
      final response = _asMap(message['response']);
      final requestId = '${response['request_id']}';
      unawaited(
        _client.answerControl(
          sessionId,
          requestId,
          response.cast<String, Object?>(),
        ),
      );
      return;
    }
    unawaited(_client.send(sessionId, message));
  }

  @override
  void close() {
    unawaited(_client.closeSession(sessionId));
    _subscription.cancel();
    _finish();
  }

  @override
  Future<void> get exited => _exited.future;
}

Map<String, Object?> _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};
