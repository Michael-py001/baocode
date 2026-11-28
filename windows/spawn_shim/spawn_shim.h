// A tiny C++ shim around CreateProcessW that catches the C++ exceptions an
// injected endpoint agent throws from inside the hooked system call. Dart
// cannot catch a native exception that unwinds through the Flutter engine's
// frame, so every spawn BaoCode makes on Windows goes through here: a thrown
// exception is turned into a result code and the caller keeps running.
//
// The same source is compiled into baocode_spawn.dll (for the resident guard
// process) and into the Windows runner (for the one spawn that starts the
// guard, see main.cpp).
#ifndef BAOCODE_SPAWN_SHIM_H_
#define BAOCODE_SPAWN_SHIM_H_

#include <windows.h>

#if defined(BAOCODE_SPAWN_SHIM_BUILD)
#define SPAWN_API __declspec(dllexport)
#elif defined(BAOCODE_SPAWN_SHIM_LOCAL)
#define SPAWN_API
#else
#define SPAWN_API __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

// The outcome of a spawn attempt.
//
//   0                       the process was created; |process| is filled.
//   ERROR_ACCESS_DENIED     an exception was caught inside CreateProcessW
//                           (the agent's C++ exception, SEH 0xE06D7363).
//   anything else           GetLastError() from CreateProcessW.
//
// When the result is nonzero, |process| is zeroed and no child exists.
//
// |application|, |command_line|, |environment| and |current_directory| are
// UTF-16 strings, all optional except |command_line| (CreateProcessW's own
// rules apply). |startup_info| is a fully prepared STARTUPINFOW or
// STARTUPINFOEXW; pass its size in |startup_size| so the shim can tell them
// apart. |creation_flags| is passed through unchanged (including
// EXTENDED_STARTUPINFO_PRESENT and DETACHED_PROCESS). |attribute_list| is the
// PROC_THREAD_ATTRIBUTE_LIST a pseudo console needs, or null. |process| must
// point at a PROCESS_INFORMATION the caller will close.
SPAWN_API DWORD spawn_seh(
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
    PROCESS_INFORMATION* process);

// The SEH code of a Microsoft C++ exception thrown by the agent. Exposed so
// the self-test and callers can tell "the hook threw" from a real Win32
// failure.
SPAWN_API DWORD spawn_cpp_exception_code();

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // BAOCODE_SPAWN_SHIM_H_
