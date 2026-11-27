# 无人值守：常驻 guard 与 spawn 服务

## 为什么

企业终端管控软件（本案是联软 UniAccess）会用内核驱动把 DLL 注入每个进程，挂钩 `CreateProcessW`。BaoCode 在 GUI 进程里起子进程（最典型是 `C:\Program Files\Git\cmd\git.exe`）时，钩子内部抛 C++ 异常，异常穿过 Flutter 引擎帧，引擎 abort，整个 GUI 退出。

Dart 的 isolate（`errorsAreFatal: false`）只挡 Dart 错误，挡不住进程级 native abort。唯一可靠的隔离是把进程创建和 agent 回合都移出 GUI 进程。

## 架构（Windows）

三个进程，各司其职：

```
BaoCode GUI ──IPC──> bao-guard.exe ──RPC over socket──> baocode-spawn.exe
     │                     │                                  │
     │                  AgentEngine                     CreateProcessW
     │                  (内置 core)                      (SEH 包裹)
     │                     │                                  │
     └── 只连 socket，不调 CreateProcessW ──────────────────────┘
```

- **baocode-spawn.exe**（`windows/spawn_shim/spawn_service.cpp`，C++）：专职进程创建。所有 `CreateProcessW` 都经 `spawn_seh`（`__try { CreateProcessW(...) } __except(...)`），注入 DLL 抛的 C++ 异常被当场接住、转成错误码返回，服务不崩。子进程的 stdout/stderr/stdin 通过匿名管道读、长度前缀帧写回 socket（协议见 `windows/spawn_shim/spawn_protocol.h`）。
- **baocode-guard.exe**（`packages/bao_remote/bin/bao_guard.dart`，纯 Dart AOT）：持有内置 core 的 `AgentEngine`（进程内，不是 isolate）。会话状态落盘 `state/guard/sessions.json`。engine 异常结束就用 `resume: sessionId` 重建、补发一条 continue 消息。它启动 spawn 服务，GUI 重启后由它接回运行中的对话。
- **BaoCode GUI**：`GuardClient` 连 guard 的 socket（`ResumableChannel` 提供断线重连、消息重放）；内置 core 的 transport 换成 `GuardTransport`。Windows 原生 runner 在创建 Flutter 窗口前用 SEH 拉起 guard（`windows/runner/main.cpp` 的 `StartGuard`），避免 GUI 自己 `Process.start` 踩钩子。

非 Windows 平台无此注入问题：guard 直接用 `dart:io Process.start`，spawn 服务不启动。

## 关键路径

- GUI 启动：`main.cpp` → `StartGuard()`（SEH）→ guard 进程 → 绑定 socket、启动 spawn 服务 → GUI `GuardClient.connect()` → `Workspace._restoreGuardSessions()` 打开运行中的对话。
- 内置 core 回合：`startClaude` → `startBuiltin` → `GuardTransport.start` → `guard session/open` → guard 内 `AgentEngine` → agent 的 Bash/git spawn 经 `SpawnClient` → C++ spawn 服务。
- 断线：GUI 崩溃 → guard 与 engine 继续运行，`ResumableChannel` 缓存未确认消息 → GUI 重开 → 重连、重放、`session/list` 找到中断会话 → 自动打开。
- 权限请求：engine 的 `can_use_tool` 在 GUI 断连时无人应答 → guard 缓存请求、重连后回放；超过 2 分钟仍无应答，回一个 deny，避免回合永久卡死。
- engine 崩溃：guard 重建 engine（`resume`）+ continue 消息；连续失败 5 次后标记 `interrupted` 停止重试。

## 文件

- `windows/spawn_shim/`：SEH shim、spawn 服务、协议、自测（`spawn_shim_test.cpp`、`test_protocol.py`）。
- `packages/bao_remote/lib/src/guard/`：guard 协议、IPC、会话表、engine 宿主、daemon、spawn 客户端。
- `packages/bao_remote/bin/bao_guard.dart`：guard 入口。
- `lib/kernel/claude_code/guard_*.dart`：GUI 侧 transport/client/options。
- `lib/remote/remote_claude.dart`、`lib/main.dart`、`lib/workspace/workspace.dart`：路由与启动恢复。
- `tool/build_windows.dart`、`windows/CMakeLists.txt`、`windows/runner/`：打包与原生 bootstrap。

## 限制

- 只防住 `CreateProcessW` 调用栈里的 C++ 异常（本案 7/9 次）。UniAccess 在 Dart VM 线程 / 目录快照等其他路径抛的异常（2/9 次）不在覆盖内，靠 guard 自动重启兜底。
- 崩溃点若正处于模型生成中途，那半句输出无法恢复（会话 JSONL 按完整块 flush）；已发出但无结果的工具调用按合成错误处理，副作用可能重复。
- ConPTY 终端仍在 guard 进程里用 `bao_conpty`（其 `CreateProcessW` 是 FFI 直调，未接 SEH）；终端路径若触发注入异常，guard 会崩并重启，由重连兜底。
- GUI 侧其余 `Process.start` 调用点（git 状态、LSP、MCP、debug adapter、更新器等）尚未逐一切换到 spawn 服务；客户端已备好，迁移是后续工作。
- 本改动较大，先在 fork 自用，后续 upstream 需拆分。

## 根治

本方案把损害限制在可重启的后台进程，**不阻止注入**。彻底解决仍需找公司 IT 把 `baocode.exe`、`baocode-guard.exe`、`baocode-spawn.exe` 加进 UniAccess 白名单。
