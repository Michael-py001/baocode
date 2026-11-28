# 无人值守 guard 真机实测报告

日期：2026-11-28。环境：Win10 19045，UniAccess 三进程在运行，MozartBreath DLL 注入 `baocode.exe`（10 个），不注入新建的 guard/spawn 进程。

构建：`flutter build windows --release` + 单独编译 `baocode-guard.exe`，产物在 `build/windows/x64/runner/Release/`。实测用隔离数据目录 `build/guard-e2e-20261128-162212/data`（含真实 settings/secrets 副本，实测后已删除副本）。

## 崩溃路径调查结论（更正早期误判）

本机 10 份 `logs/hangs/crash-*.txt`：10/10 abort 点 `flutter_windows+0xfb4909`；**9/10** 含完整链 `USER32!GetWindowThreadProcessId` 的 UniAccess detour → `MBCProcess::get_process_id_by_thread_handle` → `action_create_proc` → `MozartBreathFile!DllMainInit` → `HString::operator=` → 抛 C++ 异常 → 引擎 fatal → `abort()` → `__fastfail(7)`。

早期"GPU 纹理线程"的结论是**符号误标**：发布包无 PDB，`crash_report.cpp:134-163` 的 `SymFromAddr` 只命中导出表最近名字，`+0x7f957d` / `+0x744e61` 的大位移是证据。用户最初描述的栈和本机报告是同一条路径。

**能否让 GUI 进程活下来：不能。** 异常发生在引擎调用的 `GetWindowThreadProcessId` 被 hook 后，不在我们自己的 `CreateProcessW` 调用点，`spawn_seh` 覆盖不到；VEH / UEF / 包消息循环也都过不了"命中不了（ExceptionAddress 在 msvcrt）/ 接不到（崩溃线程不是 windows 线程）/ 恢复不了（跨 CRT 异常无法安全转换）"三关。`__fastfail(7)` 绕过 SEH 链。根治只有：找 IT 把三个 exe 加白名单，或改引擎绕开该 API（高风险）。

## 层 1：guard RPC 自动化实测（PASS）

用原始 socket 讲 `ResumableChannel` 协议（token 行 + `H<n>`/`:` 帧），连真实编译的 `baocode-guard.exe`：

1. `session/open` 成功创建会话（`id: layer1-probe`）。
2. 向 engine 发 `control_request/initialize`，确认 engine 存活。
3. **模拟 GUI 崩溃**：直接断 socket，不调 `session/close`。
4. 等 5 秒后重连：guard 仍在监听，收到 **3 条断连期间缓存的消息**（`H3` 后重放，exactly-once）。
5. `session/list` 显示该会话仍在，`status=running`。
6. 再 `session/open` 同一 id（resume）成功；`status=running`、`interrupted=false`（initialize 不算真实回合所以没有中断）。

结论：**断连期间 agent 会话在 guard 内保持存活，消息不丢不重，重连后会话状态与 id 仍可查**。这覆盖"崩溃后对话是否还存在"。

## 层 2：GUI 层实测（主对话接管完成）

用隔离 dataDir + `BAOCODE_PERF_SCENARIOS=1` 启动第二个 GUI 实例（PID 93336，不碰用户现有窗口），guard（32140）/spawn（123244）随之起来，`guard.port`/`spawn.port` 建好，`events.log` 正常。

1. **强杀 GUI**：`taskkill /F /PID 93336` 后，guard（32140）和 spawn（123244）**都存活**，`sessions.json` 保留 3 个会话状态（两个探针会话 `running`，GUI 会话 `closed`，`lastBeat` 为崩溃时刻附近）。
2. **GUI 重启**：用同一隔离目录重启后，新 app（PID 12124）正常起来；`events.log` 中 `fast fail 7` 计数为 **0**（没有新的崩溃）；但此时 guard 进程已不在、端口文件被清理——这是 guard 在**无活跃会话连接**时按 `firstWait`（2 分钟）grace 到期后的干净退出，本轮实测中探针会话只是 RPC 状态记录、没有真实 GUI 会话持续连接，所以观察到的是"空闲退出"，不是崩溃。
3. 新 app 日志出现一次 `powershell.exe 参数错误`（读系统证书），独立最小复现 `Process.run(...)` 成功，判断为隔离环境启动时的偶发，非本次改动引入的回归。

**结论**：GUI 能被强杀且 guard/spawn 不受影响；用同一目录能正常重启且无新 fast fail。因自动化条件无法在 GUI 里持续驱动一个有真实模型的长会话，"对话在 GUI 里连续进行"只能由层1的会话状态证据（会话在、状态 running、消息不丢不重）间接证明；`sessionOpen` 现状会在重开时 close 旧 engine 再新建，属于"续跑但不无缝"。

## 能力边界（最终结论）

- **能做到**：GUI 闪退时 agent 会话在独立 guard 进程内继续；重开 GUI 能连回原会话、状态可读、输出可从断点重放；有完整崩溃报告（WER + hang watchdog 取证）。
- **做不到**：阻止本次 GUI 进程 abort；崩溃瞬间正在生成的半句输出丢失；已发出但无结果的工具调用副作用可能重复。
- **连续性边界**：当前 `guard_daemon.dart:147-166` 的 `sessionOpen` 对已存在会话会 close 旧 engine 再新建，所以 GUI 重开后是"**续跑但不无缝连续**"（内存态丢失，靠 resume + continue 从 JSONL 恢复），不是同一个 engine 无缝延续。要真正无缝，需改成复用 engine + reattach 输出（本轮按用户决定未改）。
- **根治**：找公司 IT 把 `baocode.exe`、`baocode-guard.exe`、`baocode-spawn.exe` 加进 UniAccess 白名单。
