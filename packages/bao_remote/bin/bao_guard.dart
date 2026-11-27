// The resident guard: owns the built-in agent's sessions so a GUI crash
// cannot take them down, and listens on a local socket for the app to attach
// again. Started detached by the Windows runner (SEH-guarded bootstrap), or
// by the app on other platforms.
//
//   bao_guard --data <dir> [--grace <seconds>]
//
import 'dart:io';

import 'package:bao_remote/src/guard/guard_daemon.dart';
import 'package:bao_remote/src/platform/app_paths.dart';

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final at = arguments.indexOf(name);
    return at >= 0 && at + 1 < arguments.length ? arguments[at + 1] : null;
  }

  final dataDir =
      option('--data') ??
      Platform.environment['BAOCODE_DATA_DIR'] ??
      AppPaths.dataDir(Platform.environment);
  final seconds = int.tryParse(option('--grace') ?? '');
  final guard = GuardDaemon(
    dataDir: dataDir,
    grace: seconds == null
        ? const Duration(hours: 3)
        : Duration(seconds: seconds),
    log: (message) => stderr.writeln('baocode-guard: $message'),
  );
  stderr.writeln('baocode-guard: data $dataDir');
  await guard.run();
  exit(0);
}
