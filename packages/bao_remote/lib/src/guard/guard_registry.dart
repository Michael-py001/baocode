// The persisted list of sessions the guard owns. Both processes read it: the
// guard writes status as turns start and end, and the app reads it at launch
// to reopen a conversation that was running when the GUI died.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'guard_protocol.dart';

/// One session's durable record. [options] is an `EngineOptions.toJson()` map
/// (from package:bao_agent), kept as JSON so this package needs no typed
/// dependency on the engine for a value it only stores and forwards.
class GuardSessionRecord {
  const GuardSessionRecord({
    required this.id,
    required this.options,
    required this.status,
    required this.lastBeat,
    this.interrupted = false,
  });

  final String id;
  final Map<String, Object?> options;
  final GuardSessionStatus status;
  final DateTime lastBeat;
  final bool interrupted;

  Map<String, Object?> toJson() => {
    'id': id,
    'options': options,
    'status': status.wireName,
    'lastBeat': lastBeat.toUtc().toIso8601String(),
    'interrupted': interrupted,
  };

  static GuardSessionRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.isEmpty) return null;
    final options = value['options'];
    if (options is! Map) return null;
    final beat = DateTime.tryParse('${value['lastBeat']}');
    return GuardSessionRecord(
      id: id,
      options: options.cast<String, Object?>(),
      status: GuardSessionStatus.fromWire('${value['status']}'),
      lastBeat: beat ?? DateTime.fromMillisecondsSinceEpoch(0),
      interrupted: value['interrupted'] == true,
    );
  }
}

/// Reads and writes `<dataDir>/guard/sessions.json`. Writes are serialized and
/// atomic (aside, then rename) so a killed guard never leaves half a record.
class GuardRegistry {
  GuardRegistry(this.dataDir);

  final String dataDir;
  String get path => GuardAddress.sessionsPath(dataDir);

  Future<void>? _writes;
  Map<String, GuardSessionRecord> _records = {};

  /// Loads the records from disk. Call once at guard start (and once in the
  /// app before it restores running conversations).
  Future<Map<String, GuardSessionRecord>> load() async {
    final file = File(path);
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return _records;
      final parsed = [
        for (final item in decoded) GuardSessionRecord.fromJson(item),
      ].whereType<GuardSessionRecord>();
      _records = {for (final record in parsed) record.id: record};
    } on Object {
      // Missing, half-written, or malformed: start empty.
      _records = {};
    }
    return _records;
  }

  Map<String, GuardSessionRecord> get records => Map.unmodifiable(_records);

  GuardSessionRecord? operator [](String id) => _records[id];

  /// Adds or replaces one record and persists it.
  Future<void> put(GuardSessionRecord record) async {
    _records[record.id] = record;
    await _save();
  }

  /// Updates just the mutable fields of a known session.
  Future<void> update(
    String id, {
    GuardSessionStatus? status,
    bool? interrupted,
    DateTime? lastBeat,
  }) async {
    final current = _records[id];
    if (current == null) return;
    _records[id] = GuardSessionRecord(
      id: current.id,
      options: current.options,
      status: status ?? current.status,
      interrupted: interrupted ?? current.interrupted,
      lastBeat: lastBeat ?? current.lastBeat,
    );
    await _save();
  }

  /// Forgets a session.
  Future<void> remove(String id) async {
    if (_records.remove(id) == null) return;
    await _save();
  }

  Future<void> _save() {
    final previous = _writes ?? Future.value();
    final file = File(path);
    final text = jsonEncode([
      for (final record in _records.values) record.toJson(),
    ]);
    final next = previous.then((_) async {
      await file.parent.create(recursive: true);
      await _writeAtomically(file, text);
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  /// Awaits writes already under way (called before the guard exits).
  Future<void> flush() async {
    final writes = _writes;
    if (writes != null) await writes;
  }
}

/// Written aside, then renamed over: a reader never sees half a file. The
/// GUI's `writeFileAtomically` lives in lib/platform and is unavailable to a
/// plain Dart process, so this is its small equivalent.
Future<void> _writeAtomically(File file, String text) async {
  final aside = File('${file.path}.$pid.tmp');
  try {
    await aside.writeAsString(text, flush: true);
    try {
      await aside.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(text, flush: true);
    }
  } finally {
    try {
      if (await aside.exists()) await aside.delete();
    } on FileSystemException {
      // Gone already.
    }
  }
}
