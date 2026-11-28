// The guard runs only where Dart IO exists (desktop). This indirection keeps
// the transport importable on web, where the guard is never used.
import 'claude_code_transport.dart' show ClaudeLaunch;
import 'guard_options_stub.dart'
    if (dart.library.io) 'guard_options_io.dart'
    as platform;

Future<Map<String, Object?>> guardEngineOptions(ClaudeLaunch launch) =>
    platform.guardEngineOptions(launch);
