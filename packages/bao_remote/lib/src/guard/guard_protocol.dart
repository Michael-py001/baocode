import 'dart:io';

/// Messages between BaoCode and the resident guard process.
///
/// The guard owns every child process and the built-in agent, so a crash
/// caused by an injected DLL hooking `CreateProcessW` cannot take down the
/// GUI. Everything here travels as lines of JSON over the guard's local IPC
/// (Unix socket / loopback TCP + token, see [GuardAddress]).
abstract final class GuardProtocol {
  /// Bump when a message shape changes: an old guard and a new app must not
  /// silently misunderstand each other.
  static const version = 1;

  // --- Requests the app makes of the guard -------------------------------

  /// Registers a session and its engine options; answers `{id}`. The guard
  /// creates an `AgentEngine` in its own process from these options.
  static const sessionOpen = 'session/open';

  /// Feeds a stream-json user/control message to a session's engine; answers
  /// `{}` once queued.
  static const sessionSend = 'session/send';

  /// Ends a session's engine; answers `{}`.
  static const sessionClose = 'session/close';

  /// Lists persisted sessions and their status; answers `{sessions: [...]}`.
  static const sessionList = 'session/list';

  // --- Process factory requests ------------------------------------------

  /// Starts a child: params `{id, executable, arguments, workingDirectory,
  /// environment, runInShell, includeParentEnvironment, detached, stdin}`.
  /// Answers `{ok: true}`, then streams `process/output` notifications and a
  /// final `process/exit`.
  static const processStart = 'process/start';

  /// Runs a child to completion: same params plus `{input, timeoutMs}`.
  /// Answers `{exitCode, stdout(base64), stderr}`.
  static const processRun = 'process/run';

  /// Starts a pseudo console (Windows): params `{id, executable, arguments,
  /// workingDirectory, environment, columns, rows}`. Answers `{ok: true}`,
  /// then `pty/output` and `pty/exit`.
  static const ptyStart = 'pty/start';

  /// Writes bytes to a child's stdin: `{id, data(base64), close}`.
  static const processStdin = 'process/stdin';

  /// Resizes a pseudo console: `{id, columns, rows}`.
  static const ptyResize = 'pty/resize';

  /// Ends a child: `{id, force}`.
  static const processKill = 'process/kill';

  // --- Notifications the guard sends the app -----------------------------

  /// `{id, stdout(base64), stderr(base64)}` — raw bytes, never decoded, so
  /// line framing (stream-json, LSP Content-Length, MCP) survives intact.
  static const processOutput = 'process/output';

  /// `{id, exitCode}`.
  static const processExit = 'process/exit';

  /// `{id, data(base64)}` — a pseudo console's output.
  static const ptyOutput = 'pty/output';

  /// `{id, exitCode}`.
  static const ptyExit = 'pty/exit';

  /// A session's engine emitted a stream-json message; `{id, message}`.
  static const sessionMessage = 'session/message';

  /// A control request the engine needs the host to answer (permissions,
  /// hooks): `{id, requestId, request}`; the app answers with
  /// [controlResponse].
  static const controlRequest = 'control/request';

  /// The app's answer: `{id, requestId, response}`.
  static const controlResponse = 'control/response';

  /// The guard gave up waiting for the host and denied a request:
  /// `{id, requestId, reason}`.
  static const controlTimedOut = 'control/timedOut';
}

/// Where a guard listens, and how a client authenticates on Windows: the
/// loopback port and a random token in `<dataDir>/guard/guard.port` (Unix
/// uses a socket at `<dataDir>/guard/guard.sock`).
abstract final class GuardAddress {
  static const folder = 'guard';
  static const portFile = 'guard.port';
  static const socketFile = 'guard.sock';
  static const sessionsFile = 'sessions.json';

  /// The C++ spawn service advertises itself here, not in [portFile]: the
  /// service is a separate process that owns every child it creates.
  static const spawnPortFile = 'spawn.port';

  /// The guard's own data folder, derived the same way in the guard and the
  /// app (no Flutter needed).
  static String directory(String dataDir) =>
      '$dataDir${Platform.pathSeparator}$folder';

  static String portPath(String dataDir) =>
      '${directory(dataDir)}${Platform.pathSeparator}$portFile';

  /// Where the spawn service writes `<port> <token>`.
  static String spawnPortPath(String dataDir) =>
      '${directory(dataDir)}${Platform.pathSeparator}$spawnPortFile';

  static String socketPath(String dataDir) =>
      '${directory(dataDir)}${Platform.pathSeparator}$socketFile';

  static String sessionsPath(String dataDir) =>
      '${directory(dataDir)}${Platform.pathSeparator}$sessionsFile';
}

/// A persisted session's status in `sessions.json`.
enum GuardSessionStatus {
  starting,
  running,
  interrupted,
  idle,
  closed;

  String get wireName => name;

  static GuardSessionStatus fromWire(String? value) =>
      GuardSessionStatus.values.firstWhere(
        (status) => status.wireName == value,
        orElse: () => GuardSessionStatus.idle,
      );
}
