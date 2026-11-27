import 'claude_code_transport.dart' show ClaudeLaunch;

/// The guard never runs on web; this satisfies the import there.
Future<Map<String, Object?>> guardEngineOptions(ClaudeLaunch launch) async =>
    throw StateError('The guard is not available on web');
