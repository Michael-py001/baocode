// Self-test for the SEH filter. An injected endpoint agent's C++ exception
// arrives at the OS as SEH 0xE06D7363; this raises exactly that code inside a
// __try guarded by the same filter spawn_seh uses, and asserts the exception
// is caught (the process does not terminate) and an ordinary failure is not
// swallowed. Run: spawn_shim_test.exe -> exit 0 on success.
#include <windows.h>

#include <cstdio>

#include "spawn_shim.h"

namespace {

LONG WINAPI Filter(EXCEPTION_POINTERS* pointers) {
  const DWORD code = pointers->ExceptionRecord->ExceptionCode;
  if (code == spawn_cpp_exception_code() ||
      code == STATUS_ACCESS_VIOLATION ||
      code == STATUS_INVALID_PARAMETER ||
      code == STATUS_STACK_OVERFLOW) {
    return EXCEPTION_EXECUTE_HANDLER;
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

bool Report(bool ok, const char* what) {
  std::printf("%s: %s\n", ok ? "ok" : "FAIL", what);
  return ok;
}

}  // namespace

int main() {
  bool ok = true;

  // The agent's C++ exception is caught.
  DWORD caught = 0;
  __try {
    ::RaiseException(spawn_cpp_exception_code(), 0, 0, nullptr);
    caught = 1;  // no exception: wrong
  } __except (Filter(GetExceptionInformation())) {
    caught = 2;
  }
  ok &= Report(caught == 2, "C++-exception SEH code is caught");

  // An unrelated SEH code is not swallowed by the filter: an outer handler
  // gets it, proving the inner filter returned EXCEPTION_CONTINUE_SEARCH.
  DWORD outer = 0;
  __try {
    __try {
      ::RaiseException(0x12345678u, 0, 0, nullptr);
    } __except (Filter(GetExceptionInformation())) {
      outer = 1;  // the filter wrongly swallowed it
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    outer = 2;  // propagated past the inner filter, as intended
  }
  ok &= Report(outer == 2,
               "unrelated exception is left to Windows");

  // spawn_seh refuses a null process without ever calling CreateProcessW.
  const DWORD bad = spawn_seh(nullptr, nullptr, nullptr, nullptr, 0, 0,
                              nullptr, nullptr, nullptr, 0, nullptr, nullptr);
  ok &= Report(bad == ERROR_INVALID_PARAMETER,
               "spawn_seh rejects a null PROCESS_INFORMATION");

  // The normal path still creates a child (cmd /c exit 7 -> code 7).
  wchar_t command[] = L"cmd.exe /c exit 7";
  STARTUPINFOW info = {};
  info.cb = sizeof(info);
  PROCESS_INFORMATION process = {};
  const DWORD spawn = spawn_seh(nullptr, command, nullptr, nullptr, 0, 0,
                                nullptr, nullptr, &info, sizeof(info),
                                nullptr, &process);
  if (spawn == 0) {
    ::WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 0;
    ::GetExitCodeProcess(process.hProcess, &code);
    ::CloseHandle(process.hThread);
    ::CloseHandle(process.hProcess);
    ok &= Report(code == 7, "spawn_seh creates a child and reports its exit");
  } else {
    ok &= Report(false, "spawn_seh creates a child");
  }

  std::printf("%s\n", ok ? "ALL OK" : "FAILED");
  return ok ? 0 : 1;
}
