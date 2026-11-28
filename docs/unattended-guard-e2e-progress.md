# 崩溃路径调查 + 守护实测 — 进度

- [x] 调查崩溃栈（9/10 有 GetWindowThreadProcessId hook 抛异常；"GPU 线程"是符号误标）
- [x] 评估守护能力边界（不能阻止 GUI abort；可重启/会话可续）
- [x] 1. 更正 docs/unattended-guard-real-machine-check.md 的错误结论（9/10 栈含 UniAccess hook、符号误标、GUI 内无法可靠阻止 abort）
- [x] 2. 层1：guard RPC 自动化实测 PASS（会话创建→断连→重连收到 3 条缓存消息→会话仍 running→reopen 成功）
- [x] 3. 层2：GUI 实测（新对话卡在批准，主对话接管完成）：强杀 GUI 后 guard/spawn 存活、同目录重启正常、fast fail 7 计数 0
- [x] 4. 实测报告（docs/unattended-guard-e2e-report.md）+ 提交推送

## 实测记录

- 层1 PASS：会话断连后仍在、状态 running、重连收到 3 条缓存消息（exactly-once）
- 层2：GUI 强杀后 guard（32140）/spawn（123244）存活；sessions.json 保留 3 个会话；重启 app（12124）正常，无新 fast fail 7
- 连续性已升级：sessionOpen 复用 engine + reattach 输出（reused:true、interrupted:false），集成测试 PASS；不再 close/rebuild
- 隔离目录与真实 settings/secrets 副本已删除；用户现有两个 BaoCode 进程未受影响
