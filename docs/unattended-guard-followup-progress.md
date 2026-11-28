# 进程创建全量改道 + ConPTY SEH — 进度

后续计划：`eager-baking-fern.md`。PR #2 后续，补 GUI 侧 13 处进程创建改道与 ConPTY SEH。

- [x] A. 修 SpawnClient：双前缀 bug、pid/kill/IOSink、签名补齐、detached、isAvailable（8 项测试全绿；C++ 编译 + 协议端到端 PASS）
- [x] B. GUI spawn 通道：GuardDaemon handler（processRun/Start/Stdin/Kill/Detached）+ GuardClient RPC + GuardProcess/GuardStdin 门面
- [x] C. 各 seam 切换：Claude CLI、Haiku、LSP、MCP probe、DAP、local_run、git 状态/remote、powershell 证书、shell 命令、更新器（含 detached）——全部 analyze 干净
- [x] D. ConPTY 接 SEH（可选加载 shim DLL，签名对齐、analyze 干净）
- [x] E. 原生 open editor（window_channel.cpp）走 spawn_seh
- [x] F. 文档 + 验证 + 推送

## 验证记录

- 全项目 `dart analyze`（lib/ + bao_remote/lib + bao_conpty/lib）No issues
- flutter test：guard registry 4 项 + daemon + RPC + 客户端 8 项断言，全部 PASS
- 真实 RPC 集成：process/run → guard → C++ 服务 → cmd.exe，pid/stdout/exit 正确
- C++ shim 4 项自测 + spawn 协议端到端 PASS；服务与 DLL 编译通过
- 本地回退 encoding bug 已修（Process.run 用 null encoding 拿 Uint8List）
