// Local IPC for the guard: Unix domain socket, or loopback TCP + a token
// file on Windows (Dart has no Unix sockets there). Adapted from
// server_session.dart's private _bindTcp/_bind/_token, which are tied to a
// remote-project session and cannot be reused directly.
import 'dart:io';
import 'dart:math';

import '../server/server_session.dart' show ServerSession;
import 'guard_protocol.dart';

/// A bound guard listener and the token a client must present on Windows
/// (null on Unix, where a socket file's permissions are the gate).
class GuardListener {
  GuardListener(this.socket, this.token, this.addressFile);

  final ServerSocket socket;
  final String? token;
  final String addressFile;

  /// Whether a guard is already listening at [dataDir].
  static Future<bool> isListening(String dataDir) async {
    if (Platform.isWindows) {
      final address = await readAddress(dataDir);
      if (address == null) return false;
      try {
        final other = await Socket.connect(
          InternetAddress.loopbackIPv4,
          address.port,
          timeout: const Duration(seconds: 2),
        );
        other.destroy();
        return true;
      } on SocketException {
        return false;
      }
    }
    final path = GuardAddress.socketPath(dataDir);
    if (!File(path).existsSync()) return false;
    try {
      final other = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 2),
      );
      other.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  /// Binds the guard's address. Throws [AlreadyServing] when another guard is
  /// already there; removes a stale file left by a killed one first.
  static Future<GuardListener> bind(String dataDir) async {
    await Directory(GuardAddress.directory(dataDir)).create(recursive: true);
    return Platform.isWindows ? _bindTcp(dataDir) : _bindUnix(dataDir);
  }

  static Future<GuardListener> _bindTcp(String dataDir) async {
    final path = GuardAddress.portPath(dataDir);
    final token = _token();
    final file = File(path);
    if (file.existsSync()) {
      final port = int.tryParse(
        file.readAsStringSync().trim().split(' ').first,
      );
      if (port != null) {
        try {
          final other = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            timeout: const Duration(seconds: 2),
          );
          other.destroy();
          throw const AlreadyServing();
        } on SocketException {
          // Left behind by a killed guard: replace it.
        }
      }
    }
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final partial = File('$path.${_token().substring(0, 8)}.tmp');
    await partial.writeAsString('${listener.port} $token', flush: true);
    await partial.rename(path);
    return GuardListener(listener, token, path);
  }

  static Future<GuardListener> _bindUnix(String dataDir) async {
    final path = GuardAddress.socketPath(dataDir);
    if (await isListening(dataDir)) throw const AlreadyServing();
    await File(path).parent.create(recursive: true);
    try {
      await File(path).delete();
    } on FileSystemException {
      // None there.
    }
    final listener = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    return GuardListener(listener, null, path);
  }

  /// Reads `<port> <token>` from a running guard's address file; null when
  /// there is none.
  static Future<({int port, String token})?> readAddress(String dataDir) async {
    if (!Platform.isWindows) return null;
    final file = File(GuardAddress.portPath(dataDir));
    if (!file.existsSync()) return null;
    final parts = file.readAsStringSync().trim().split(RegExp(r'\s+'));
    if (parts.length != 2) return null;
    final port = int.tryParse(parts[0]);
    if (port == null) return null;
    return (port: port, token: parts[1]);
  }

  /// Removes the address file on a clean exit.
  Future<void> deleteAddress() async {
    try {
      await File(addressFile).delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  static String _token() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// The gate a Windows client's first line must pass; the guard side uses this
/// same helper so both ends agree.
Future<Stream<List<int>>?> guardAfterToken(
  Stream<List<int>> input,
  String token,
) => ServerSession.afterToken(input, token);

class AlreadyServing implements Exception {
  const AlreadyServing();

  @override
  String toString() => 'A guard is already listening';
}
