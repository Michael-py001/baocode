// Wire protocol between BaoCode (or the Dart guard) and baocode-spawn.exe.
//
// All integers are little-endian uint32. A connection is a sequence of
// frames. The client opens one connection per child process.
//
// Request frame (client -> server), after the token line:
//
//   [u32 commandLineBytes][u32 cwdBytes][u32 envBytes]
//   [u32 flags][u32 stdinMode]
//   [commandLine UTF-16LE][cwd UTF-16LE][environment UTF-16LE blocks]
//
//   envBytes is a double-null-terminated UTF-16LE environment block (the
//   same shape CreateProcessW takes), or 0 for "inherit".
//   flags: bit0 = runInShell (use cmd /c), bit1 = detached.
//   stdinMode: 0 = no stdin, 1 = pipe (client sends stdin/write frames).
//
// Response frames (server -> client), each: [u32 type][u32 length][bytes]
//
//   type 1 stdout   bytes = raw stdout bytes
//   type 2 stderr   bytes = raw stderr bytes
//   type 3 exit     bytes = 4 bytes, int32 exit code
//   type 4 failed   bytes = 4 bytes, uint32 Win32 error (5 = hook threw)
//   type 5 pid      bytes = 4 bytes, uint32 process id (after successful spawn)
//
// Client frames after spawn (client -> server), for stdinMode 1:
//
//   [u32 type][u32 length][bytes]
//     type 1 = stdin bytes, type 2 = close stdin, type 3 = kill child.
//   type 3 is a zero-length control frame; the server TerminateProcesses the
//   child and ends its wait. It shares the number 3 with the server->client
//   exit frame but is not related (different direction).
//
// The server reads stdout/stderr on anonymous pipes with ReadFile and writes
// frames as bytes arrive; every CreateProcessW goes through spawn_seh so an
// injected DLL's exception cannot abort the service.
#ifndef BAOCODE_SPAWN_PROTOCOL_H_
#define BAOCODE_SPAWN_PROTOCOL_H_

namespace spawn_proto {

constexpr unsigned char kStdout = 1;
constexpr unsigned char kStderr = 2;
constexpr unsigned char kExit = 3;
constexpr unsigned char kFailed = 4;
constexpr unsigned char kPid = 5;

constexpr unsigned char kStdinWrite = 1;
constexpr unsigned char kStdinClose = 2;
constexpr unsigned char kKill = 3;  // client -> server: terminate the child

constexpr unsigned int kFlagRunInShell = 1u << 0;
constexpr unsigned int kFlagDetached = 1u << 1;

constexpr unsigned int kStdinNone = 0;
constexpr unsigned int kStdinPipe = 1;

}  // namespace spawn_proto

#endif  // BAOCODE_SPAWN_PROTOCOL_H_
