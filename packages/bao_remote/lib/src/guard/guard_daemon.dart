// The resident guard: owns the app's agent sessions and answers the app's
// process-spawn requests over local IPC. Runs as a plain Dart process, so a
// crash in the GUI cannot take it down; the GUI reconnects to its socket and
// carries on where it left off.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show EngineOptions, newUuid;
import 'package:bao_remote/protocol.dart'
    show ChannelEnd, ChannelLink, ResumableChannel, RpcPeer;

import 'guard_ipc.dart';
import 'guard_protocol.dart';
import 'guard_registry.dart';
import 'guard_session.dart';
import 'guard_spawn_client.dart'
    show SpawnClient, SpawnedProcess, startSpawnService;

class GuardDaemon {
  GuardDaemon({
    required this.dataDir,
    this.grace = const Duration(hours: 3),
    void Function(String message)? log,
  }) : log = log ?? ((message) {});

  final String dataDir;
  final Duration grace;
  final void Function(String message) log;

  late final GuardRegistry registry = GuardRegistry(dataDir);
  late final SpawnClient spawn = SpawnClient(dataDir);
  late final ResumableChannel channel = ResumableChannel(
    heartbeat: const Duration(seconds: 5),
    silence: const Duration(seconds: 45),
  );
  late final RpcPeer peer = RpcPeer(channel.messages, channel.send);

  final Map<String, GuardSession> _sessions = {};
  final Map<String, SpawnedProcess> _processes = {};
  GuardListener? _listener;
  Timer? _graceTimer;
  bool _closed = false;

  /// Starts listening and serves until the grace period runs out with no
  /// connection, or [stop] is called.
  Future<void> run() async {
    await registry.load();
    if (Platform.isWindows) {
      // The C++ spawn service owns every child process. Starting it is one
      // fixed CreateProcessW call (not a user-supplied path), so the injected
      // hook's path-dependent throw does not bite here; after this, all
      // spawns go to the service's SEH-guarded CreateProcessW.
      final guardExe = Platform.resolvedExecutable;
      final dir = File(guardExe).parent.path;
      final spawnExe = '$dir${Platform.pathSeparator}baocode-spawn.exe';
      if (File(spawnExe).existsSync() &&
          !await SpawnClient.isAvailable(dataDir)) {
        try {
          await startSpawnService(dataDir, executable: spawnExe);
        } on Object catch (error) {
          log('could not start the spawn service: $error');
        }
      }
    }
    _registerHandlers();

    try {
      _listener = await GuardListener.bind(dataDir);
    } on AlreadyServing {
      log('a guard is already listening');
      return;
    }
    log('listening on ${_listener!.addressFile}');

    _listener!.socket.listen(_onConnection);
    channel.linkChanges.listen(_onLink);
    _armGrace(_firstWait);

    final end = await Future.any([
      peer.done.then((_) => ChannelEnd.closed),
      channel.ended,
    ]);
    log('ending: ${end.name}');
    await stop();
  }

  static const _firstWait = Duration(minutes: 2);

  void _onLink(bool up) {
    if (up) {
      _graceTimer?.cancel();
      _graceTimer = null;
      // A session whose permission questions were asked while detached gets
      // them replayed now the host is back.
      for (final session in _sessions.values) {
        session.replayPending();
      }
    } else {
      _armGrace(grace);
    }
  }

  void _armGrace(Duration limit) {
    _graceTimer?.cancel();
    _graceTimer = Timer(limit, () {
      log('no connection for ${limit.inSeconds}s: ending');
      channel.close();
    });
  }

  void _onConnection(Socket socket) {
    unawaited(socket.done.then((_) {}, onError: (Object _) {}));
    final listener = _listener;
    if (listener == null) {
      socket.destroy();
      return;
    }
    Future<Stream<List<int>>?> input;
    if (listener.token == null) {
      input = Future.value(socket);
    } else {
      input = guardAfterToken(socket, listener.token!);
    }
    unawaited(
      input.then((stream) {
        if (stream == null) {
          log('a connection without the token: refused');
          socket.destroy();
          return;
        }
        unawaited(
          channel.attach(
            ChannelLink(
              input: stream,
              write: socket.add,
              close: socket.destroy,
            ),
          ),
        );
      }),
    );
  }

  /// A session's engine output goes to the app as a notification. Kept as a
  /// factory so reattach can swap in the same closure for a new connection.
  void Function(Map<String, Object?> message) get _sessionSend =>
      (message) => peer.notify(GuardProtocol.sessionMessage, message);

  void _registerHandlers() {
    peer.handlers[GuardProtocol.sessionOpen] = (params, call) async {
      final map = _asMap(params);
      var optionsJson = _asMap(map['options']).cast<String, Object?>();
      // Pin an id so the guard's key and the engine's own session id agree
      // (AgentSession otherwise makes one up when neither field is set).
      if (optionsJson['sessionId'] == null && optionsJson['resume'] == null) {
        optionsJson = {...optionsJson, 'sessionId': newUuid()};
      }
      final options = EngineOptions.fromJson(optionsJson);
      final id = options.sessionId ?? options.resume ?? '';
      // A reconnecting GUI must reuse the live engine, not close and rebuild
      // it: that would interrupt the running turn and lose in-memory state.
      final existing = _sessions[id];
      if (existing != null && existing.reattach(_sessionSend)) {
        return {'id': id, 'reused': true};
      }
      final session = GuardSession(
        options: options,
        send: _sessionSend,
        registry: registry,
        log: log,
      );
      _sessions[id] = session;
      return {'id': id, 'reused': false};
    };

    peer.handlers[GuardProtocol.sessionSend] = (params, call) async {
      final map = _asMap(params);
      final session = _sessions['${map['id']}'];
      if (session == null) return {'ok': false};
      session.receive(_asMap(map['message']).cast<String, Object?>());
      return {'ok': true};
    };

    peer.handlers[GuardProtocol.sessionClose] = (params, call) async {
      final map = _asMap(params);
      final id = '${map['id']}';
      await _sessions.remove(id)?.close();
      return {'ok': true};
    };

    peer.handlers[GuardProtocol.sessionList] = (params, call) async => {
      'sessions': [
        for (final record in registry.records.values) record.toJson(),
      ],
    };

    peer.handlers[GuardProtocol.controlResponse] = (params, call) async {
      final map = _asMap(params);
      final session = _sessions['${map['id']}'];
      session?.answerControl(
        '${map['requestId']}',
        _asMap(map['response']).cast<String, Object?>(),
      );
      return {'ok': true};
    };

    peer.handlers[GuardProtocol.processRun] = (params, call) async {
      final map = _asMap(params);
      final run = await spawn.run(
        executable: '${map['executable']}',
        arguments: _texts(map['arguments']),
        workingDirectory: map['workingDirectory'] as String?,
        environment: _strings(map['environment']),
        runInShell: map['runInShell'] == true,
        includeParentEnvironment: map['includeParentEnvironment'] == true,
        input: _bytes(map['input']),
        timeout: Duration(milliseconds: _int(map['timeoutMs']) ?? 30000),
      );
      return {
        'exitCode': run.exitCode,
        'pid': run.pid,
        'stdout': base64Encode(run.stdout),
        'stderr': run.stderr,
      };
    };

    peer.handlers[GuardProtocol.processStart] = (params, call) async {
      final map = _asMap(params);
      final id = '${map['id']}';
      final process = await spawn.start(
        executable: '${map['executable']}',
        arguments: _texts(map['arguments']),
        workingDirectory: map['workingDirectory'] as String?,
        environment: _strings(map['environment']),
        runInShell: map['runInShell'] == true,
        includeParentEnvironment: map['includeParentEnvironment'] == true,
      );
      final previous = _processes.remove(id);
      unawaited(previous?.kill());
      _processes[id] = process;
      // Feed the app's stdout/stderr notifications as raw bytes.
      process.stdout.listen((bytes) {
        peer.notify(GuardProtocol.processOutput, {
          'id': id,
          'stdout': base64Encode(bytes),
          'stderr': '',
        });
      });
      process.stderr.listen((bytes) {
        peer.notify(GuardProtocol.processOutput, {
          'id': id,
          'stdout': '',
          'stderr': base64Encode(bytes),
        });
      });
      unawaited(
        process.exitCode.then((code) {
          _processes.remove(id);
          peer.notify(GuardProtocol.processExit, {'id': id, 'exitCode': code});
        }),
      );
      // The pid frame may still be in flight; wait for it so the app gets a
      // real pid rather than -1.
      return {'ok': true, 'pid': await process.pidReady()};
    };

    peer.handlers[GuardProtocol.processStdin] = (params, call) async {
      final map = _asMap(params);
      final process = _processes['${map['id']}'];
      final data = _bytes(map['data']);
      if (process != null && data != null) process.stdin.add(data);
      if (map['close'] == true) unawaited(process?.stdin.close());
      return {'ok': process != null};
    };

    peer.handlers[GuardProtocol.processKill] = (params, call) async {
      final map = _asMap(params);
      final process = _processes.remove('${map['id']}');
      final ok = process == null ? false : await process.kill();
      return {'ok': ok};
    };

    peer.handlers[GuardProtocol.processDetached] = (params, call) async {
      final map = _asMap(params);
      final pid = await spawn.spawnDetached(
        executable: '${map['executable']}',
        arguments: _texts(map['arguments']),
        workingDirectory: map['workingDirectory'] as String?,
        environment: _strings(map['environment']),
        runInShell: map['runInShell'] == true,
        includeParentEnvironment: map['includeParentEnvironment'] == true,
      );
      return {'pid': pid};
    };
  }

  /// Stops the daemon: closes sessions, persists state, removes the address.
  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    _graceTimer?.cancel();
    for (final session in _sessions.values) {
      await session.close();
    }
    _sessions.clear();
    await registry.flush();
    peer.close();
    channel.close();
    await _listener?.socket.close();
    await _listener?.deleteAddress();
  }
}

Map<String, Object?> _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

List<String> _texts(Object? value) =>
    value is List ? [for (final item in value) '$item'] : const [];

Map<String, String> _strings(Object? value) => value is Map
    ? {for (final entry in value.entries) '${entry.key}': '${entry.value}'}
    : const {};

int? _int(Object? value) => value is int ? value : int.tryParse('$value');

Uint8List? _bytes(Object? value) {
  if (value is! String) return null;
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}
