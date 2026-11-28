cmake_minimum_required(VERSION 3.14)

# baocode_spawn.dll: the SEH-guarded CreateProcessW shim. Built as its own
# target so the resident guard (a plain Dart process) can call it over FFI.
# spawn_shim.cpp is also compiled directly into the runner for the one spawn
# that starts the guard; there, SEH cannot come from a DLL import.
add_library(baocode_spawn SHARED
  "spawn_shim.cpp"
)
apply_standard_settings(baocode_spawn)
target_compile_options(baocode_spawn PRIVATE /utf-8)
target_compile_definitions(baocode_spawn PRIVATE "NOMINMAX"
  "BAOCODE_SPAWN_SHIM_BUILD")

# The guard is a plain process; carry the VC++ runtime beside the DLL rather
# than depend on a system copy that may be older (same as baocode_wer).
set_property(TARGET baocode_spawn PROPERTY
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# A small self-test: it throws a C++ exception inside a __try/__except that
# goes through the same filter as spawn_seh, and checks the process survives.
add_executable(spawn_shim_test
  "spawn_shim_test.cpp"
  "spawn_shim.cpp"
)
apply_standard_settings(spawn_shim_test)
target_compile_options(spawn_shim_test PRIVATE /utf-8)
target_compile_definitions(spawn_shim_test PRIVATE "NOMINMAX"
  "BAOCODE_SPAWN_SHIM_LOCAL")

# baocode-spawn.exe: owns every CreateProcessW in its own process so an
# injected endpoint hook can only crash this helper, not the GUI. A console
# target (no WIN32 subsystem) keeps stdout debug available; detached children
# are spawned with DETACHED_PROCESS so no console window pops up. It links
# spawn_shim.cpp directly (no DLL import) and installs beside baocode.exe.
add_executable(baocode-spawn
  "spawn_service.cpp"
  "spawn_shim.cpp"
)
apply_standard_settings(baocode-spawn)
target_compile_options(baocode-spawn PRIVATE /utf-8)
target_compile_definitions(baocode-spawn PRIVATE "NOMINMAX"
  "BAOCODE_SPAWN_SHIM_LOCAL")
target_link_libraries(baocode-spawn PRIVATE "ws2_32.lib")
set_property(TARGET baocode-spawn PROPERTY
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
install(TARGETS baocode-spawn RUNTIME
  DESTINATION "$<TARGET_FILE_DIR:baocode>" COMPONENT Runtime)
