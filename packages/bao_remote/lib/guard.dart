/// The resident guard: a local process that owns the app's agent sessions
/// (so a GUI crash cannot take them down) and, on Windows, the spawn service
/// that keeps CreateProcessW off the GUI's stack.
library;

export 'protocol.dart';
export 'src/guard/guard_protocol.dart';
export 'src/guard/guard_registry.dart';
export 'src/guard/guard_ipc.dart' show GuardListener, AlreadyServing;
