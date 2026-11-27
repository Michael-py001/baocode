// One session owned by the guard. It holds an AgentEngine in the guard's own
// process (not a GUI isolate), so the engine survives the GUI, and it rebuilds
// the engine with `resume` if a turn fails — then nudges the model with a
// continue message instead of replaying the whole user prompt.
import 'dart:async';

import 'package:bao_agent/bao_agent.dart' show AgentEngine, EngineOptions;

import 'guard_protocol.dart';
import 'guard_registry.dart';

/// The nudge sent to a rebuilt engine: carry on from the transcript rather
/// than replaying the user's last prompt.
const _continuePrompt =
    'The usage limit has reset. Continue where you left off.';

/// How long a `can_use_tool` request waits for the host before the guard
/// denies it itself, so a detached turn cannot hang forever.
const _permissionWait = Duration(minutes: 2);

/// Stop rebuilding after this many failures (e.g. no API key): an engine that
/// dies on start every time must not spin forever.
const _maxRebuilds = 5;

class GuardSession {
  GuardSession({
    required this.options,
    required this.send,
    required this.registry,
    required this.log,
  }) : sessionId = options.sessionId ?? options.resume ?? '' {
    _open();
  }

  final EngineOptions options;
  final void Function(Map<String, Object?> message) send;
  final GuardRegistry registry;
  final void Function(String message) log;
  final String sessionId;

  AgentEngine? _engine;
  int _rebuilds = 0;
  bool _closed = false;
  bool _rebuilding = false;

  /// Control requests the engine asked the host to answer, by request id.
  final _pendingRequests = <String, _PendingRequest>{};

  void _open() {
    final engine = AgentEngine(
      _rebuilds == 0 ? options : _resumeOptions(),
      send: _onEngineMessage,
    );
    _engine = engine;
    unawaited(
      engine.done.then((_) {
        if (_closed || _rebuilding || !identical(_engine, engine)) return;
        // The engine ended while the session is still meant to be alive: a
        // turn failed. Rebuild with resume and nudge it to carry on.
        log('session $sessionId engine ended unexpectedly; rebuilding');
        unawaited(rebuild());
      }),
    );
    if (_rebuilds > 0) {
      // A fresh engine after a failed turn: resume from the last complete
      // message and ask the model to carry on, without replaying the prompt.
      engine.receive({
        'type': 'user',
        'message': {'role': 'user', 'content': _continuePrompt},
      });
    }
    unawaited(
      registry.put(
        GuardSessionRecord(
          id: sessionId,
          options: options.toJson(),
          status: GuardSessionStatus.running,
          lastBeat: DateTime.now().toUtc(),
          interrupted: _rebuilds > 0,
        ),
      ),
    );
  }

  EngineOptions _resumeOptions() {
    // Resume the same conversation; the transcript is already on disk and
    // SessionStore repairs dangling tool calls on load.
    final base = options;
    return EngineOptions(
      cwd: base.cwd,
      resume: sessionId,
      sessionId: sessionId,
      model: base.model,
      permissionMode: base.permissionMode,
      effort: base.effort,
      thinkingDisplay: base.thinkingDisplay,
      autocompact: base.autocompact,
      persist: base.persist,
      directories: base.directories,
      flagSettings: base.flagSettings,
      sdkServers: base.sdkServers,
      appendSystemPrompt: base.appendSystemPrompt,
      promptSuggestions: base.promptSuggestions,
      environment: base.environment,
      rootCertificates: base.rootCertificates,
      configDir: base.configDir,
      productName: base.productName,
      systemPrompt: base.systemPrompt,
      coreSystemPrompt: base.coreSystemPrompt,
      tools: base.tools,
      maxTurns: base.maxTurns,
      strictMcpConfig: base.strictMcpConfig,
      slashCommands: base.slashCommands,
      canAsk: base.canAsk,
    );
  }

  void _onEngineMessage(Map<String, Object?> message) {
    final type = message['type'];
    if (type == 'control_request') {
      final requestId = message['request_id'];
      final request = message['request'];
      if (requestId is String && request is Map) {
        final timer = Timer(_permissionWait, () {
          if (_pendingRequests.remove(requestId) == null) return;
          // Timed out with no host attached: deny, so the turn can finish.
          _engine?.receive({
            'type': 'control_response',
            'response': {
              'subtype': 'success',
              'request_id': requestId,
              'response': {
                'behavior': 'deny',
                'message': 'No host answered the permission request in time.',
              },
            },
          });
        });
        _pendingRequests[requestId] = _PendingRequest(timer, message);
      }
    }
    send({...message, 'sessionId': sessionId});
  }

  /// The app answered a control request (or timed out and denied it).
  void answerControl(String requestId, Map<String, Object?>? response) {
    final pending = _pendingRequests.remove(requestId);
    pending?.timer.cancel();
    _engine?.receive({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': response ?? const {'behavior': 'deny'},
      },
    });
  }

  /// Replays requests the app has not answered yet after it reconnects, so a
  /// permission question asked while detached is not silently lost.
  void replayPending() {
    for (final entry in _pendingRequests.entries) {
      send({...entry.value.message, 'sessionId': sessionId});
    }
  }

  /// Feeds a stream-json message from the app to the engine.
  void receive(Map<String, Object?> message) => _engine?.receive(message);

  /// Rebuilds the engine after a failed turn. Called by the daemon when the
  /// engine ends unexpectedly while a turn was in flight.
  Future<void> rebuild() async {
    if (_closed) return;
    if (_rebuilds >= _maxRebuilds) {
      log('session $sessionId gave up after $_maxRebuilds rebuilds');
      await registry.update(
        sessionId,
        status: GuardSessionStatus.interrupted,
        interrupted: true,
      );
      return;
    }
    _rebuilding = true;
    final old = _engine;
    _engine = null;
    _rebuilds++;
    for (final pending in _pendingRequests.values) {
      pending.timer.cancel();
    }
    _pendingRequests.clear();
    if (old != null) await old.close().catchError((Object _) {});
    _rebuilding = false;
    _open();
    log('session $sessionId rebuilt (attempt $_rebuilds)');
  }

  /// Ends the session for good.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pendingRequests.values) {
      pending.timer.cancel();
    }
    _pendingRequests.clear();
    await _engine?.close().catchError((Object _) {});
    _engine = null;
    await registry.update(sessionId, status: GuardSessionStatus.closed);
  }
}

class _PendingRequest {
  const _PendingRequest(this.timer, this.message);

  final Timer timer;
  final Map<String, Object?> message;
}
