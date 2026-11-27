#include "spawn_shim.h"

namespace {

// Microsoft's C++ exceptions are carried as SEH with this code. The endpoint
// agent's exception is one of these; catching the code keeps the filter
// deliberate about what it swallows.
constexpr DWORD kCppException = 0xE06D7363u;

// No C++ objects with destructors in here: MSVC forbids __try in a function
// that needs object unwinding (C2712). Only raw WinAPI calls.
LONG WINAPI Filter(EXCEPTION_POINTERS* pointers) {
  const DWORD code = pointers->ExceptionRecord->ExceptionCode;
  // A C++ exception from the hook is the case we are guarding. An access
  // violation raised by the hook is just as fatal to the caller if it
  // escapes, so it is caught too and reported as a failed spawn.
  if (code == kCppException || code == STATUS_ACCESS_VIOLATION ||
      code == STATUS_INVALID_PARAMETER || code == STATUS_STACK_OVERFLOW) {
    return EXCEPTION_EXECUTE_HANDLER;
  }
  // Anything else keeps Windows' own handling.
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

extern "C" {

DWORD spawn_cpp_exception_code() { return kCppException; }

DWORD spawn_seh(
    const wchar_t* application,
    wchar_t* command_line,
    LPSECURITY_ATTRIBUTES process_attributes,
    LPSECURITY_ATTRIBUTES thread_attributes,
    BOOL inherit_handles,
    DWORD creation_flags,
    const wchar_t* environment,
    const wchar_t* current_directory,
    void* startup_info,
    DWORD startup_size,
    void* attribute_list,
    PROCESS_INFORMATION* process) {
  if (process == nullptr) return ERROR_INVALID_PARAMETER;
  ::ZeroMemory(process, sizeof(*process));
  if (command_line == nullptr) return ERROR_INVALID_PARAMETER;

  // Let the caller hand the pseudo-console attribute list in either through
  // STARTUPINFOEXW.lpAttributeList or as its own argument.
  LPSTARTUPINFOW info = static_cast<LPSTARTUPINFOW>(startup_info);
  if (attribute_list != nullptr && info != nullptr &&
      startup_size >= sizeof(STARTUPINFOEXW)) {
    reinterpret_cast<LPSTARTUPINFOEXW>(info)->lpAttributeList =
        static_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attribute_list);
  }

  __try {
    const BOOL ok = ::CreateProcessW(
        application, command_line, process_attributes, thread_attributes,
        inherit_handles, creation_flags,
        const_cast<wchar_t*>(environment),
        const_cast<wchar_t*>(current_directory), info, process);
    if (ok) return 0;
    return ::GetLastError();
  } __except (Filter(GetExceptionInformation())) {
    // The injected agent threw inside CreateProcessW. No child was created;
    // |process| is still zero. Report it as a distinct failure so callers can
    // tell the hook from an ordinary Win32 error.
    return ERROR_ACCESS_DENIED;
  }
}

}  // extern "C"
