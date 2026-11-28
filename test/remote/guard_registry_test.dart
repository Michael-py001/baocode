import 'dart:io';

import 'package:bao_remote/guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard's session table survives a restart: a killed guard leaves a
/// whole file behind, and the app reads it at launch to reopen a conversation
/// that was running.
void main() {
  late Directory dir;
  late GuardRegistry registry;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guard-registry-');
    registry = GuardRegistry(dir.path);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Gone already.
    }
  });

  GuardSessionRecord record(String id, GuardSessionStatus status) =>
      GuardSessionRecord(
        id: id,
        options: {'cwd': dir.path, 'model': 'test'},
        status: status,
        lastBeat: DateTime.utc(2026, 11, 27),
      );

  test('round-trips through disk', () async {
    await registry.put(record('abc', GuardSessionStatus.running));
    final fresh = GuardRegistry(dir.path);
    await fresh.load();
    expect(fresh['abc']?.status, GuardSessionStatus.running);
    expect(fresh['abc']?.options['model'], 'test');
    expect(fresh['abc']?.lastBeat, DateTime.utc(2026, 11, 27));
  });

  test('updates status and interrupted flag', () async {
    await registry.put(record('abc', GuardSessionStatus.running));
    await registry.update(
      'abc',
      status: GuardSessionStatus.interrupted,
      interrupted: true,
    );
    final fresh = GuardRegistry(dir.path);
    await fresh.load();
    expect(fresh['abc']?.status, GuardSessionStatus.interrupted);
    expect(fresh['abc']?.interrupted, isTrue);
  });

  test('removes a session', () async {
    await registry.put(record('abc', GuardSessionStatus.idle));
    await registry.put(record('def', GuardSessionStatus.idle));
    await registry.remove('abc');
    final fresh = GuardRegistry(dir.path);
    await fresh.load();
    expect(fresh.records.keys, ['def']);
  });

  test('a malformed file starts empty', () async {
    final file = File(GuardAddress.sessionsPath(dir.path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('not json');
    final fresh = GuardRegistry(dir.path);
    expect(await fresh.load(), isEmpty);
  });
}
