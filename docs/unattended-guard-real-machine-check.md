# 真机验证记录（UniAccess 注入环境）

日期：2026-11-28。环境：Win10 19045，UniAccess 三进程在运行（UniAccessAgentDaemon/Agent/Tray）。

## 确认的事实

1. **注入是按目标进程的**：用 `CreateToolhelp32Snapshot(TH32CS_SNAPMODULE)` 枚举——
   - 运行中的 `baocode.exe`（PID 90548）有 **10 个** UniAccess DLL：`MozartBreathCore/OM/Fw/File/Process/Bolo2/Protect/Soft`、`OverlordSpear`、`Vozokopot`，路径 `C:\WINDOWS\LVUAAgentInstBaseRoot\system32`。
   - 新建的探针 C++/Dart 进程、以及 `baocode-browser-host.exe`：**0 个**注入模块。
   - 含义：guard 和 spawn 服务作为新进程启动，**不会被注入**，其内部 `CreateProcessW` 天然安全；这是本方案成立的关键前提，已实测确认。
2. **本机崩溃报告确实含 UniAccess 进程创建 hook 栈（已更正早期误判）**：`logs/hangs/crash-*.txt` 共 10 份，10/10 的 `[crashed]` 线程首帧都是 `flutter_windows+0xfb4909`（abort 点），其中 **9/10** 含完整链：`flutter_windows` → `USER32!GetWindowThreadProcessId` 的 UniAccess detour → `MBCProcess::get_process_id_by_thread_handle` → `MBCProcess::action_create_proc` → `MozartBreathFile!DllMainInit` → `HString::operator=` / `ascii_str_to_hs` → `RaiseException(0xE06D7363)`。用户描述的栈与本机报告是同一条路径。
   - 早先把栈顶标成 `InternalFlutterGpu_Texture_InitializeFromImage`、把 hook 调用点标成 `WindowManager_UpdatePopupPosition` 是**符号误标**：发布包没有随 DLL 部署 PDB，`crash_report.cpp:134-163` 的 `SymFromAddr` 只命中导出表最近的前一个名字，`+0x7f957d` / `+0x744e61` 这种几十万字节位移就是证据。仓库里也没有 `UpdatePopupPosition` 实现。
   - 注入 DLL 用的是 Microsoft Detours（`.detourd`/`.detourc` 节），hook 的目标是窗口所属的进程/线程查询 API `GetWindowThreadProcessId`，不是我们自己的 `CreateProcessW` 调用。
3. 直接在新进程（未注入）里起 `C:\Program Files\Git\cmd\git.exe`（带空格路径）成功，`git version 2.56.0.windows.2`，无崩溃——符合"未注入进程不受影响"。
4. SEH 自测在本机真实环境下 4/4 通过：`RaiseException(0xE06D7363)` 被 `__except` 接住；无关异常不外泄；参数校验；正常 spawn。

## 结论与边界

- 崩溃确实是 UniAccess 的 API hook 抛 C++ 异常 → Flutter 引擎 fatal → `abort()` → `__fastfail(7)`；但被 hook 的 API 是 **`GetWindowThreadProcessId`**（引擎的窗口管理路径调用），不是我们自己的 `CreateProcessW` 调用点。
- 因此：`spawn_seh` 只覆盖我们主动发起的 `CreateProcessW`（StartGuard/open-editor/ConPTY/各 spawn seam），**覆盖不到这次崩溃的调用点**；GUI 进程内加 VEH / UEF / 包消息循环 `__try` 也都过不了"命中不了（ExceptionAddress 在 msvcrt 不在 Mozart）/ 接不到（崩溃线程不是 windows 线程）/ 恢复不了（跨 CRT 的 C++ 异常无法安全转成正常返回）"三关。用现有架构**不能让这一次的 GUI 进程活下来**。
- 守护能做到的是把"GUI 闪退"降级为"GUI 可重启、会话可续、有完整报告"：guard/spawn 不被注入且强杀 GUI 后存活（已实测），engine 在 guard 内运行、恢复靠 resume + continue。根治仍需找 IT 把三个 exe 加进 UniAccess 白名单（或改引擎绕开该 API，高风险）。
- 真机复现完整崩溃条件（特定入参触发钩子抛异常）不可控，无法用"跑一次不崩"证明"闪退已消除"；可用证据只有模块注入枚举、SEH 自测、全链路 RPC 集成与下面的新构建实测。

## 新构建实测（2026-11-28）

用 `flutter build windows --release` + 单独编译 `baocode-guard.exe` 放进 Release 目录，以隔离数据目录 + `BAOCODE_PERF_SCENARIOS=1` 启动第二个实例（不碰用户现有窗口）：

1. **启动**：app 起来后 `baocode-guard.exe` 与 `baocode-spawn.exe` 均存活，`guard.port` / `spawn.port` 建好。
2. **模拟 GUI 崩溃**：`taskkill /F` 强杀 app 进程后，guard 与 spawn **都存活**，guard 端口仍在。
3. **进程创建**：干净的启动里，guard/spawn 从 1 秒起稳定存活；通过 guard 的 `process/run` RPC 起 `cmd.exe /c exit 7` 拿到真实 pid、stdout、退出码（自动化测试 PASS）。
4. **grace 行为**：没有会话连接时，guard 在 `firstWait`（2 分钟）后干净退出并删除 `guard.port`；这是设计行为。有活跃会话时 `_onLink(up)` 会取消该计时器。测试中没有真实会话，故观察到的是"空闲退出"，不是崩溃。

### 过程中发现并修复的两个真实 bug

- CMake 编译 `baocode_spawn.dll` 时未定义 `BAOCODE_SPAWN_SHIM_BUILD`，导出宏不一致导致 `C4273` 被 `/WX` 当错误 → Release 构建失败。已修。
- `StartGuard()` 用 `DETACHED_PROCESS` 起 Dart guard，进程无有效 std 句柄，首次 `stderr.writeln` 即以 255 退出。用 GUI 子系统探针复现并验证：改 `CREATE_NO_WINDOW` 后 guard 存活（STILL_ACTIVE）。已修。

## 待办

- 让新构建在这台机器上日常使用一段时间，观察 `events.log` 是否还出现 `fast fail 7`；这是判断方案是否真正消除闪退的最终判据。
- 若仍出现 GPU 线程 abort，需回到根因分析（显卡驱动 `igd10um64xe` 也在崩溃栈中出现），与本方案无关。
