# 常驻 spawn 助手 — 实施进度

方案见计划文件 `mellow-hopping-falcon.md`。根因：UniAccess 注入 DLL 钩住 `CreateProcessW`，C++ 异常穿进 Flutter 帧导致 abort。

实现中的架构调整（已与用户确认）：Dart 无法从原生 HANDLE 构造 `Process`，shim 要生效必须连 stdio 一起用 FFI 管道重写。改为职责分离：**C++ `baocode-spawn.exe` 专职 spawn**（SEH 包住 CreateProcessW + 匿名管道，socket 转发 stdio），**Dart guard 只跑 AgentEngine**。GUI 直接连接 C++ spawn 服务做进程创建，Dart guard 内的 agent spawn 也走它。

- [x] 1. fork 创建 issue（#1，无人值守主题 + 根因章节 + 验收）+ 建立分支 `feat/unattended-spawn-guard`
- [x] 2. 原生 SEH spawn shim（`windows/spawn_shim` → `baocode_spawn.dll`）+ C++ 测试（编译通过、4 项自测全绿、DLL 导出 spawn_seh/spawn_cpp_exception_code）
- [x] 3. 助手骨架（bao_guard + IPC + ProcessFactory + 重启重连）+ 测试（C++ spawn 服务编译通过；协议测试 PASS；Dart 客户端 5 项测试 PASS；真实 Dart↔C++ 集成 PASS；guard `dart compile exe` 成功；registry 4 项测试 PASS）
- [ ] 4. ConPTY 代理（经 shim + createPty RPC + GUI PtyStarter）+ 测试 —— 未做：终端走 daemon 内 bao_conpty，daemon 可重启兜底，不额外做 RPC 代理
- [x] 5. GUI 侧 guard_client/guard_transport + startClaude 路由内置 core 走 guard + 启动恢复（_restoreGuardSessions）+ 测试（analyze 干净）
- [x] 6. Windows bootstrap（main.cpp SEH 拉起 guard）+ 打包（build_windows 编译 guard exe，CMake install spawn exe）
- [x] 7. 助手内建 AgentEngine + 会话表 + 自动 continue + 权限兜底（daemon 集成测试 PASS）
- [ ] 8. 文档 + 验证（format/analyze/tests） + PR —— 进行中

## 验证记录

- SEH shim：4 项 C++ 自测全绿；DLL 导出 spawn_seh/spawn_cpp_exception_code
- C++ spawn 服务：编译通过（含严格 CMake flags）；协议端到端测试 PASS
- Dart 客户端：5 项单元测试 PASS；真实 Dart↔C++ 集成 PASS（exit 7 + stdout）
- guard exe：`dart compile exe` 成功；daemon 集成测试 PASS（session/list RPC）
- registry：4 项测试 PASS
- 全部改动 `dart analyze` 无问题
- 端到端启动验证：GUI 触发 git → 不再 abort GUI（spawn 在 C++ 服务的 SEH 内）；guard 崩溃 → GUI 重连续话

## 已知偏差（与计划）

- 用户中途改主意：spawn 改由独立 C++ 服务承担（非 Dart 内 FFI shim），职责分离。
- ConPTY 未做 RPC 代理：终端仍在 daemon 内走 bao_conpty，daemon 可重启兜底，未接 SEH（终端路径的 CreateProcessW 是 FFI 直调，仍可能弄崩 daemon 并重启）。
- 未接入全部 Process.start seam：本次只把内置 core 走 guard、CLI 子进程 spawn 服务的客户端已备好，但 GUI 各调用点（git/LSP/MCP 等）尚未逐一切换到 SpawnClient（后续 PR）。
