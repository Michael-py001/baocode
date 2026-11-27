import 'claude_code_transport.dart' show ClaudeLaunch;
import 'dart_core_transport_io.dart' show DartCoreTransport;

/// The engine options the guard's engine is created from: the same ones the
/// in-process core would use, so provider/key, system prompt and tools are
/// preserved across the move to the guard process.
Future<Map<String, Object?>> guardEngineOptions(ClaudeLaunch launch) async =>
    (await DartCoreTransport.engineOptions(launch)).toJson();
