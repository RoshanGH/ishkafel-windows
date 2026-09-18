# 故障报告实施计划

**目标：** 完成不依赖人工后台的一键提交、API 查询与处理闭环。
**技术：** Dart/Flutter；Python WSGI、MySQL、Waitress；报告压缩存 MySQL BLOB，SQLite 只用于测试。
**设计：** ../specs/2026-09-18-diagnostic-reports-design.md
**执行：** 当前会话顺序执行；公司服务器已提供，使用 IP HTTPS 部署。

- [x] 服务端：server/diagnostics/app.py，实现鉴权、校验、幂等持久化、分页、详情、处理状态。先编写真实 WSGI 请求测试，覆盖鉴权越权、异常输入、重复提交、附件、状态和分页。
- [x] 客户端：lib/core/diagnostics/report_service.dart，实现脱敏、限量读取、硬件采集、原子出站队列、HTTPS 上传及失败恢复。测试临时目录 + 本地 HTTP 服务真实请求，注入连接失败验证保留与重传。
- [x] 现场记录：进程执行入口记录工具/阶段/退出码/耗时及有限错误；全局入口提交报告，可选描述与截图。测试不填字段提交和重复点击保护。
- [x] 独立诊断：提供主界面无响应时的 Windows 采集脚本入口，复用日志和协议。异常退出记录不能误称原生崩溃原因。
- [x] 部署与 Agent 使用：Docker、持久卷、HTTPS 配置说明、查询工具；不将读取/处理 token 注入客户端。
- [x] 验证：Python 服务测试、Dart 定向测试、analyze、完整 Flutter 测试、正式脚本 Release 构建、真机提交到公司 HTTPS/MySQL 服务并读取报告；线上验收通过，正式分发包就绪。详细记录见 docs/windows-port/2026-09-18-diagnostics-acceptance.md。
