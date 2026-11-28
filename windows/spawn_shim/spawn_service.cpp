// baocode-spawn.exe: the standalone process that owns every CreateProcessW
// BaoCode asks for. An injected endpoint DLL that throws a C++ exception from
// inside the hooked CreateProcessW can only take down this helper, never the
// GUI: every spawn goes through spawn_seh (see spawn_shim.h).
//
// Wire protocol: spawn_protocol.h. The service binds 127.0.0.1:<port>, the
// Dart client connects and sends the token as its first line, then one
// request frame per child process. Usage:
//   baocode-spawn.exe --port 49152 --token <hex>
// The positional form `baocode-spawn.exe <port> <token_hex>` works too.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "spawn_protocol.h"
#include "spawn_shim.h"

#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>

namespace {

constexpr DWORD kMaxFieldBytes = 64u * 1024u * 1024u;
constexpr DWORD kReadChunk = 8192u;
constexpr DWORD kFlushGraceMs = 1000u;
constexpr size_t kMaxLineBytes = 4096u;
constexpr size_t kMaxTokenHex = 256u;

struct Config {
  u_short port;
  char tokenHex[kMaxTokenHex];
  unsigned char tokenRaw[kMaxTokenHex / 2];
  DWORD tokenRawLen;
};
Config g_config;

// Only one CreateProcessW runs at a time: while it runs, the child-side pipe
// ends are inheritable, and we do not want a concurrent child inheriting a
// different connection's ends (that would keep its stdout pipe open forever).
CRITICAL_SECTION g_spawnLock;

struct ScopedHandle {
  HANDLE h;
  explicit ScopedHandle(HANDLE value = nullptr) : h(value) {}
  ~ScopedHandle() {
    if (h != nullptr) ::CloseHandle(h);
  }
  HANDLE get() const { return h; }
  void reset(HANDLE value = nullptr) {
    if (h != nullptr) ::CloseHandle(h);
    h = value;
  }
  HANDLE release() {
    HANDLE value = h;
    h = nullptr;
    return value;
  }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;
};

struct ScopedSocket {
  SOCKET s;
  explicit ScopedSocket(SOCKET value = INVALID_SOCKET) : s(value) {}
  ~ScopedSocket() {
    if (s != INVALID_SOCKET) ::closesocket(s);
  }
  SOCKET get() const { return s; }
  ScopedSocket(const ScopedSocket&) = delete;
  ScopedSocket& operator=(const ScopedSocket&) = delete;
};

struct ScopedCriticalSection {
  CRITICAL_SECTION cs;
  ScopedCriticalSection() { ::InitializeCriticalSection(&cs); }
  ~ScopedCriticalSection() { ::DeleteCriticalSection(&cs); }
  CRITICAL_SECTION* ptr() { return &cs; }
  ScopedCriticalSection(const ScopedCriticalSection&) = delete;
  ScopedCriticalSection& operator=(const ScopedCriticalSection&) = delete;
};

struct WideBuf {
  wchar_t* p;
  explicit WideBuf(size_t count) : p(new wchar_t[count]) {}
  ~WideBuf() { delete[] p; }
  wchar_t* get() const { return p; }
  WideBuf(const WideBuf&) = delete;
  WideBuf& operator=(const WideBuf&) = delete;
};

void put_u32(unsigned char* out, uint32_t value) {
  out[0] = static_cast<unsigned char>(value & 0xffu);
  out[1] = static_cast<unsigned char>((value >> 8) & 0xffu);
  out[2] = static_cast<unsigned char>((value >> 16) & 0xffu);
  out[3] = static_cast<unsigned char>((value >> 24) & 0xffu);
}

bool recv_exact(SOCKET sock, void* dst, size_t bytes) {
  char* out = static_cast<char*>(dst);
  while (bytes != 0) {
    const int want = bytes > static_cast<size_t>(INT_MAX) ? INT_MAX : static_cast<int>(bytes);
    const int got = ::recv(sock, out, want, 0);
    if (got <= 0) return false;
    out += got;
    bytes -= static_cast<size_t>(got);
  }
  return true;
}

bool send_all(SOCKET sock, const void* src, size_t bytes) {
  const char* in = static_cast<const char*>(src);
  while (bytes != 0) {
    const int want = bytes > static_cast<size_t>(INT_MAX) ? INT_MAX : static_cast<int>(bytes);
    const int sent = ::send(sock, in, want, 0);
    if (sent <= 0) return false;
    in += sent;
    bytes -= static_cast<size_t>(sent);
  }
  return true;
}

bool recv_u32(SOCKET sock, uint32_t* out) {
  unsigned char raw[4];
  if (!recv_exact(sock, raw, sizeof(raw))) return false;
  *out = static_cast<uint32_t>(raw[0]) |
         (static_cast<uint32_t>(raw[1]) << 8) |
         (static_cast<uint32_t>(raw[2]) << 16) |
         (static_cast<uint32_t>(raw[3]) << 24);
  return true;
}

// Every frame goes out under the connection's lock: stdout/stderr readers and
// the worker (pid / failed / exit) all share the same socket.
bool send_frame(SOCKET sock, CRITICAL_SECTION* lock, unsigned char type,
                const void* payload, uint32_t bytes) {
  unsigned char header[8];
  put_u32(header, type);
  put_u32(header + 4, bytes);
  ::EnterCriticalSection(lock);
  const bool ok = send_all(sock, header, sizeof(header)) &&
                  (bytes == 0 || send_all(sock, payload, bytes));
  ::LeaveCriticalSection(lock);
  return ok;
}

bool send_u32_frame(SOCKET sock, CRITICAL_SECTION* lock, unsigned char type,
                    uint32_t value) {
  unsigned char raw[4];
  put_u32(raw, value);
  return send_frame(sock, lock, type, raw, sizeof(raw));
}

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool set_token_hex(const char* hex) {
  const size_t len = std::strlen(hex);
  if (len == 0 || len > kMaxTokenHex - 1 || (len & 1u) != 0) return false;
  std::memcpy(g_config.tokenHex, hex, len);
  g_config.tokenHex[len] = '\0';
  for (size_t i = 0; i < len; i += 2) {
    const int hi = hex_value(hex[i]);
    const int lo = hex_value(hex[i + 1]);
    if (hi < 0 || lo < 0) return false;
    g_config.tokenRaw[i / 2] = static_cast<unsigned char>((hi << 4) | lo);
  }
  g_config.tokenRawLen = static_cast<DWORD>(len / 2);
  return true;
}

void narrow_arg(const wchar_t* src, char* dst, size_t cap) {
  size_t i = 0;
  for (; src[i] != L'\0' && i + 1 < cap; ++i) dst[i] = static_cast<char>(src[i]);
  dst[i] = '\0';
}

bool parse_port(const char* text, u_short* port) {
  char* end = nullptr;
  const unsigned long value = std::strtoul(text, &end, 10);
  if (end == text || value == 0 || value > 65535) return false;
  *port = static_cast<u_short>(value);
  return true;
}

bool parse_args(int argc, wchar_t** argv) {
  char arg[kMaxTokenHex];
  for (int i = 1; i < argc; ++i) {
    if (std::wcscmp(argv[i], L"--port") == 0 && i + 1 < argc) {
      narrow_arg(argv[++i], arg, sizeof(arg));
      if (!parse_port(arg, &g_config.port)) return false;
    } else if (std::wcscmp(argv[i], L"--token") == 0 && i + 1 < argc) {
      narrow_arg(argv[++i], arg, sizeof(arg));
      if (!set_token_hex(arg)) return false;
    } else if (g_config.port == 0) {
      narrow_arg(argv[i], arg, sizeof(arg));
      if (!parse_port(arg, &g_config.port)) return false;
    } else {
      narrow_arg(argv[i], arg, sizeof(arg));
      if (!set_token_hex(arg)) return false;
    }
  }
  return g_config.port != 0 && g_config.tokenRawLen != 0;
}

bool read_token_line(SOCKET sock, char* line, size_t cap, size_t* outLen) {
  size_t len = 0;
  while (len + 1 < cap) {
    const int got = ::recv(sock, line + len, 1, 0);
    if (got <= 0) return false;
    if (line[len] == '\n') {
      line[len] = '\0';
      *outLen = len;
      return true;
    }
    ++len;
  }
  return false;
}

// The token is passed to us as hex; the client may send either the decoded
// bytes or that same hex text as the first line. Both name the same secret.
bool token_ok(const char* line, size_t len) {
  if (len != 0 && line[len - 1] == '\r') --len;
  if (len == g_config.tokenRawLen &&
      std::memcmp(line, g_config.tokenRaw, len) == 0) {
    return true;
  }
  return len == std::strlen(g_config.tokenHex) &&
         std::memcmp(line, g_config.tokenHex, len) == 0;
}

struct PipeReaderCtx {
  SOCKET sock;
  HANDLE pipe;
  unsigned char type;
  CRITICAL_SECTION* lock;
};

DWORD WINAPI pipe_reader(LPVOID param) {
  PipeReaderCtx* ctx = static_cast<PipeReaderCtx*>(param);
  char buf[kReadChunk];
  for (;;) {
    DWORD bytes = 0;
    if (!::ReadFile(ctx->pipe, buf, static_cast<DWORD>(sizeof(buf)), &bytes, nullptr) ||
        bytes == 0) {
      break;
    }
    send_frame(ctx->sock, ctx->lock, ctx->type, buf, static_cast<uint32_t>(bytes));
  }
  delete ctx;
  return 0;
}

struct StdinCtx {
  SOCKET sock;
  HANDLE pipe;
  HANDLE process;  // for the type 3 kill control frame
};

DWORD WINAPI stdin_pump(LPVOID param) {
  StdinCtx* ctx = static_cast<StdinCtx*>(param);
  for (;;) {
    uint32_t type = 0;
    uint32_t len = 0;
    if (!recv_u32(ctx->sock, &type) || !recv_u32(ctx->sock, &len) ||
        len > kMaxFieldBytes) {
      break;
    }
    if (type == spawn_proto::kStdinClose) break;
    if (type == spawn_proto::kKill) {
      // Zero-length control frame: terminate the child and end the wait.
      ::TerminateProcess(ctx->process, 1);
      break;
    }
    if (type != spawn_proto::kStdinWrite) break;
    char buf[kReadChunk];
    uint32_t left = len;
    while (left != 0) {
      const DWORD chunk = left < sizeof(buf) ? left : static_cast<DWORD>(sizeof(buf));
      DWORD written = 0;
      if (!recv_exact(ctx->sock, buf, chunk) ||
          !::WriteFile(ctx->pipe, buf, chunk, &written, nullptr) || written != chunk) {
        ::CloseHandle(ctx->pipe);
        delete ctx;
        return 0;
      }
      left -= chunk;
    }
  }
  ::CloseHandle(ctx->pipe);
  delete ctx;
  return 0;
}

void serve_connection(SOCKET rawSocket) {
  ScopedSocket sock(rawSocket);
  char line[kMaxLineBytes];
  size_t lineLen = 0;
  if (!read_token_line(sock.get(), line, sizeof(line), &lineLen) ||
      !token_ok(line, lineLen)) {
    return;
  }

  ScopedCriticalSection sendLock;
  uint32_t cmdBytes = 0;
  uint32_t cwdBytes = 0;
  uint32_t envBytes = 0;
  uint32_t flags = 0;
  uint32_t stdinMode = 0;
  if (!recv_u32(sock.get(), &cmdBytes) || !recv_u32(sock.get(), &cwdBytes) ||
      !recv_u32(sock.get(), &envBytes) || !recv_u32(sock.get(), &flags) ||
      !recv_u32(sock.get(), &stdinMode)) {
    return;
  }
  const bool badSizes = cmdBytes == 0 || (cmdBytes & 1u) != 0 ||
                        (cwdBytes & 1u) != 0 || (envBytes & 1u) != 0 ||
                        cmdBytes > kMaxFieldBytes || cwdBytes > kMaxFieldBytes ||
                        envBytes > kMaxFieldBytes;
  if (badSizes) {
    send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kFailed,
                   ERROR_INVALID_PARAMETER);
    return;
  }

  WideBuf cmd(cmdBytes / 2 + 1);
  if (!recv_exact(sock.get(), cmd.get(), cmdBytes)) return;
  cmd.get()[cmdBytes / 2] = L'\0';

  WideBuf cwd(cwdBytes != 0 ? cwdBytes / 2 + 1 : 1);
  if (cwdBytes != 0) {
    if (!recv_exact(sock.get(), cwd.get(), cwdBytes)) return;
    cwd.get()[cwdBytes / 2] = L'\0';
  }
  WideBuf env(envBytes != 0 ? envBytes / 2 + 2 : 1);
  if (envBytes != 0) {
    if (!recv_exact(sock.get(), env.get(), envBytes)) return;
    env.get()[envBytes / 2] = L'\0';
    env.get()[envBytes / 2 + 1] = L'\0';
  }

  // CreateProcessW may modify its command-line buffer, so build a private,
  // mutable copy (with room for the shell prefix).
  static const wchar_t kShellPrefix[] = L"cmd.exe /c ";
  const size_t prefix = (flags & spawn_proto::kFlagRunInShell) != 0
                            ? sizeof(kShellPrefix) / sizeof(wchar_t) - 1
                            : 0;
  WideBuf commandLine(prefix + cmdBytes / 2 + 1);
  if (prefix != 0) {
    std::memcpy(commandLine.get(), kShellPrefix, prefix * sizeof(wchar_t));
  }
  std::memcpy(commandLine.get() + prefix, cmd.get(), cmdBytes);
  commandLine.get()[prefix + cmdBytes / 2] = L'\0';

  SECURITY_ATTRIBUTES inherit{};
  inherit.nLength = sizeof(inherit);
  inherit.bInheritHandle = TRUE;
  HANDLE raw = nullptr;
  HANDLE write = nullptr;
  ScopedHandle outRead;
  ScopedHandle outWrite;
  ScopedHandle errRead;
  ScopedHandle errWrite;
  ScopedHandle inRead;
  ScopedHandle inWrite;
  if (!::CreatePipe(&raw, &write, &inherit, 0)) {
    send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kFailed, ::GetLastError());
    return;
  }
  outRead.reset(raw);
  outWrite.reset(write);
  if (!::CreatePipe(&raw, &write, &inherit, 0)) {
    send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kFailed, ::GetLastError());
    return;
  }
  errRead.reset(raw);
  errWrite.reset(write);
  if (stdinMode == spawn_proto::kStdinPipe) {
    if (!::CreatePipe(&raw, &write, &inherit, 0)) {
      send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kFailed, ::GetLastError());
      return;
    }
    inRead.reset(raw);
    inWrite.reset(write);
  }
  // Detached children outlive this connection: no pipe inheritance and no
  // wait. They are not given our stdio handles, so no reader threads run.
  const bool detached = (flags & spawn_proto::kFlagDetached) != 0;
  if (detached) {
    // bInheritHandles is TRUE below; strip every pipe end so the detached child
    // cannot keep this connection's pipes open after we return.
    ::SetHandleInformation(outRead.get(), HANDLE_FLAG_INHERIT, 0);
    ::SetHandleInformation(outWrite.get(), HANDLE_FLAG_INHERIT, 0);
    ::SetHandleInformation(errRead.get(), HANDLE_FLAG_INHERIT, 0);
    ::SetHandleInformation(errWrite.get(), HANDLE_FLAG_INHERIT, 0);
    if (inRead.get() != nullptr) ::SetHandleInformation(inRead.get(), HANDLE_FLAG_INHERIT, 0);
    if (inWrite.get() != nullptr) ::SetHandleInformation(inWrite.get(), HANDLE_FLAG_INHERIT, 0);
  } else {
    // Only the child-facing ends stay inheritable.
    ::SetHandleInformation(outRead.get(), HANDLE_FLAG_INHERIT, 0);
    ::SetHandleInformation(errRead.get(), HANDLE_FLAG_INHERIT, 0);
    if (inWrite.get() != nullptr) {
      ::SetHandleInformation(inWrite.get(), HANDLE_FLAG_INHERIT, 0);
    }
  }
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  if (!detached) {
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = outWrite.get();
    si.hStdError = errWrite.get();
    si.hStdInput = inRead.get();
  }
  PROCESS_INFORMATION pi{};
  DWORD creationFlags = 0;
  if (detached) {
    creationFlags |= DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
  }

  DWORD result = 0;
  ::EnterCriticalSection(&g_spawnLock);
  result = spawn_seh(nullptr, commandLine.get(), nullptr, nullptr, TRUE,
                     creationFlags, envBytes != 0 ? env.get() : nullptr,
                     cwdBytes != 0 ? cwd.get() : nullptr, &si, sizeof(si),
                     nullptr, &pi);
  if (result == 0) {
    // The parent must drop these for EOF to arrive, while still under the
    // lock so no other child can inherit them.
    outWrite.reset();
    errWrite.reset();
    inRead.reset();
  }
  ::LeaveCriticalSection(&g_spawnLock);

  if (result != 0) {
    send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kFailed, result);
    return;
  }
  ScopedHandle process(pi.hProcess);
  ScopedHandle thread(pi.hThread);
  send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kPid,
                 static_cast<uint32_t>(pi.dwProcessId));

  if (detached) {
    // The client expects only the pid frame, then disconnects. Do not wait on
    // the child: a detached process is meant to outlive this connection, and
    // a client disconnect here is normal (do not kill the child).
    return;
  }

  ScopedHandle outThread;
  ScopedHandle errThread;
  ScopedHandle inThread;
  PipeReaderCtx* outCtx = new PipeReaderCtx{
      sock.get(), outRead.get(), spawn_proto::kStdout, sendLock.ptr()};
  HANDLE created = ::CreateThread(nullptr, 0, pipe_reader, outCtx, 0, nullptr);
  if (created != nullptr) {
    outThread.reset(created);
  } else {
    delete outCtx;
  }
  PipeReaderCtx* errCtx = new PipeReaderCtx{
      sock.get(), errRead.get(), spawn_proto::kStderr, sendLock.ptr()};
  created = ::CreateThread(nullptr, 0, pipe_reader, errCtx, 0, nullptr);
  if (created != nullptr) {
    errThread.reset(created);
  } else {
    delete errCtx;
  }
  if (stdinMode == spawn_proto::kStdinPipe) {
    StdinCtx* stdinCtx = new StdinCtx{sock.get(), inWrite.release(), process.get()};
    created = ::CreateThread(nullptr, 0, stdin_pump, stdinCtx, 0, nullptr);
    if (created != nullptr) {
      inThread.reset(created);
    } else {
      ::CloseHandle(stdinCtx->pipe);
      delete stdinCtx;
    }
  }

  ::WaitForSingleObject(process.get(), INFINITE);
  DWORD exitCode = 0;
  ::GetExitCodeProcess(process.get(), &exitCode);

  if (inThread.get() != nullptr) {
    // Unblock a pump waiting for more stdin frames (send side stays open so
    // the exit frame can still go out).
    ::shutdown(sock.get(), SD_RECEIVE);
    ::WaitForSingleObject(inThread.get(), kFlushGraceMs);
  }
  if (outThread.get() != nullptr) {
    ::WaitForSingleObject(outThread.get(), kFlushGraceMs);
  }
  if (errThread.get() != nullptr) {
    ::WaitForSingleObject(errThread.get(), kFlushGraceMs);
  }
  send_u32_frame(sock.get(), sendLock.ptr(), spawn_proto::kExit,
                 static_cast<uint32_t>(static_cast<int32_t>(exitCode)));
  // ponytail: readers that miss the 1s grace are not force-killed; their pipe
  // handles close on scope exit. Upgrade to overlapped cancels if that ever
  // shows up as a real stalled-socket case.
}

DWORD WINAPI connection_worker(LPVOID param) {
  serve_connection(reinterpret_cast<SOCKET>(param));
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (!parse_args(argc, argv)) {
    std::fputs("usage: baocode-spawn.exe --port <port> --token <hex>\n", stderr);
    return 2;
  }
  ::InitializeCriticalSection(&g_spawnLock);

  WSADATA wsa{};
  if (::WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 3;
  const SOCKET listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listener == INVALID_SOCKET) return 4;
  int reuse = 1;
  ::setsockopt(listener, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = ::htons(g_config.port);
  addr.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
  if (::bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    ::closesocket(listener);
    return 5;
  }
  if (::listen(listener, SOMAXCONN) != 0) {
    ::closesocket(listener);
    return 6;
  }

  // Plain accept loop: one worker per connection. The service stays up until
  // it is terminated; the protocol has no shutdown frame.
  for (;;) {
    const SOCKET client = ::accept(listener, nullptr, nullptr);
    if (client == INVALID_SOCKET) continue;
    const HANDLE worker = ::CreateThread(
        nullptr, 0, connection_worker,
        reinterpret_cast<LPVOID>(static_cast<uintptr_t>(client)), 0, nullptr);
    if (worker == nullptr) {
      ::closesocket(client);
    } else {
      ::CloseHandle(worker);
    }
  }
}
