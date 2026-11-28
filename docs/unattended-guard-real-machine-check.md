# 真机验证记录（UniAccess 注入环境）

日期：2026-11-28。环境：Win10 19045，UniAccess 三进程在运行（UniAccessAgentDaemon/Agent/Tray）。

## 确认的事实

1. **注入是按目标进程的**：用 `CreateToolhelp32Snapshot(TH32CS_SNAPMODULE)` 枚举——
   - 运行中的 `baocode.exe`（PID 90548）有 **10 个** UniAccess DLL：`MozartBreathCore/OM/Fw/File/Process/Bolo2/Protect/Soft`、`OverlordSpear`、`Vozokopot`，路径 `C:\WINDOWS\LVUAAgentInstBaseRoot\system32`。
   - 新建的探针 C++/Dart 进程、以及 `baocode-browser-host.exe`：**0 个**注入模块。
   - 含义：guard 和 spawn 服务作为新进程启动，**不会被注入**，其内部 `CreateProcessW` 天然安全；这是本方案成立的关键前提，已实测确认。
2. **本机崩溃报告的栈与用户描述不一致**：`logs/hangs/crash-*.txt` 共 10 份，崩溃线程全部是 Flutter GPU 纹理线程（`InternalFlutterGpu_Texture_InitializeFromImage+...`），abort 点统一 `flutter_windows+0xfb4909`，**没有一份**出现 `CreateProcessW` / `MBCProcess::action_create_proc`。用户描述的 WER 栈（CreateProcessW → MBCProcess::action_create_proc）无法用本机报告复现；可能是 WER 报告的原始异常帧，而本地 crash handler 记录的是 abort 点。此点未证实。
3. 直接在新进程（未注入）里起 `C:\Program Files\Git\cmd\git.exe`（带空格路径）成功，`git version 2.56.0.windows.2`，无崩溃——符合"未注入进程不受影响"。
4. SEH 自测在本机真实环境下 4/4 通过：`RaiseException(0xE06D7363)` 被 `__except` 接住；无关异常不外泄；参数校验；正常 spawn。

## 结论与边界

- 方案对"被注入的 baocode.exe 调 CreateProcessW 导致 abort"这一路径是**结构性正确**的：GUI 侧主要 spawn 已改道 guard（新进程，未注入），ConPTY/open-editor 走 `spawn_seh`。
- 但本机实际崩溃栈是 GPU 线程，**本方案不覆盖该路径**。若 abort 的真正原因不是 CreateProcessW 钩子，本方案不能消除这些崩溃。这一点必须诚实标注，不能声称"已修复闪退"。
- 真机复现完整崩溃条件（特定入参触发钩子抛异常）不可控，无法用"跑一次不崩"证明修复；能用证据只有模块注入枚举 + SEH 自测 + 全链路 RPC 集成测试。

## 待办

- 用新构建的 baocode.exe（含本方案）在这台机器上实际运行一段时间，观察 `events.log` 是否还出现 `fast fail 7`；这是唯一的最终判据。
- 若仍出现 GPU 线程 abort，需回到根因分析（显卡驱动 `igd10um64xe` 也在崩溃栈中出现），与本方案无关。
