# GPT Switcher 1.2 技术验证

验证日期：2026-09-03（Asia/Shanghai）

## 修正后的结论

用户需要的是“多个账号共享同一套本地项目与历史”，不是完整 Profile 隔离。1.0 把 `CODEX_HOME` 分别指向 A/B，导致每个账号创建独立的项目、会话和任务数据库，因而左侧内容不同。

本机只读检查确认：

| 位置 | 检查结果 |
|---|---|
| 官方默认 `~/.codex` | 约 4.3 GB，包含 `sessions`、`session_index.jsonl`、`thread_history_1.sqlite`、`state_5.sqlite` 等现有工作数据 |
| 1.0 Account A `codex` | 约 472 MB，没有默认目录的历史会话索引 |
| 1.0 Account B `codex` | 约 456 MB，没有默认目录的历史会话索引 |

因此 1.2 延续共享工作区的日常启动形式：

```text
open -n \
  --env CODEX_HOME=~/.codex \
  --env CODEX_ELECTRON_USER_DATA_PATH="$HOME/Library/Application Support/Codex" \
  /Applications/ChatGPT.app \
  --args --user-data-dir="$HOME/Library/Application Support/Codex"
```

这些参数不再指向账号目录，而是显式固定到官方默认共享目录，避免继承环境变量造成偏移。从 GPT Switcher、Dock 或 Finder 启动时，都会使用相同的官方默认本地状态。

官方文档说明，桌面端“项目”视图同时包含 ChatGPT 项目和关联本机文件夹的本地项目；聊天会保留对话记录和工作目录。[项目和聊天](https://learn.chatgpt.com/zh-Hans/docs/projects)

## 账号切换机制

当前版本的 Codex 登录状态存在官方 `CODEX_HOME/auth.json`。1.2 将每个账号由官方客户端生成的该文件作为不透明快照保存：

```text
GPT Switcher profile auth.json
        ↓ 原子文件替换
~/.codex/auth.json
        ↓
使用默认共享工作区启动 ChatGPT
```

切换顺序：

1. 确认目标账号快照是普通文件、非符号链接、大小在安全范围内。
2. 请求当前 ChatGPT 正常退出并等待进程结束。
3. 若当前登录由 GPT Switcher 管理，将可能已刷新的官方登录文件保存回当前账号快照。
4. 首次切换前，将原有默认登录文件备份到 `migration-backup/original-auth.json`。
5. 用同目录临时文件和原子替换激活目标账号登录。
6. 写入只含账号 ID 的活动标记。
7. 从官方默认目录启动 ChatGPT。

GPT Switcher 不解析登录文件，也不复制 Cookie、Local Storage、Keychain、项目数据库或对话数据库。

## 新账号注册

新增 C、D 等账号时，只有首次登录窗口继续使用隔离目录：

```text
open -n \
  --env CODEX_HOME=<account>/codex \
  --env CODEX_ELECTRON_USER_DATA_PATH=<account>/chatgpt \
  /Applications/ChatGPT.app \
  --args --user-data-dir=<account>/chatgpt
```

用户在官方窗口中登录并点击“完成登录”后，工具仅激活该账号生成的 `auth.json`，随即返回默认共享工作区。隔离目录不参与日常项目与任务存储。

## 本机应用信息

| 项目 | 结果 |
|---|---|
| 实际路径 | `/Applications/ChatGPT.app` |
| Bundle Identifier | `com.openai.codex` |
| 版本 | `26.825.41651` |
| Build | `7345` |
| 架构 | Apple Silicon arm64 |
| Chromium | `151.0.7922.174` |
| 默认 Electron 数据 | `~/Library/Application Support/Codex` |
| 默认 Codex 数据 | `~/.codex` |

安装包静态检查仍确认首次登录使用的 `CODEX_ELECTRON_USER_DATA_PATH` 和 `CODEX_HOME` 可用。

## 额度接口验证

当前 ChatGPT 安装包生成的 App Server schema 定义了只读方法 `account/rateLimits/read`。响应按账号实际返回：

- `planType`
- `rateLimitsByLimitId`
- `primary` / `secondary` 窗口
- `usedPercent`
- `windowDurationMins`
- `resetsAt`（Unix 秒）

本机使用 A、B 两个现有登录快照完成真实只读验证，两者均返回 Plus、300 分钟窗口、10,080 分钟窗口，以及各自不同的剩余百分比和重置时间。查询没有切换活动账号，也没有输出或保存后台 `accountId`。

实现不根据 Plus/Pro 名称硬编码窗口：优先使用 `rateLimitsByLimitId`，仅显示服务器实际返回的数据。官方说明本地消息与云端聊天共用五小时窗口，此外还可能有周限额；Pro 提供 Plus 的 5 倍或 20 倍额度。[OpenAI 定价与用量说明](https://learn.chatgpt.com/zh-Hans/docs/pricing)

## 自动化验证

Swift Testing 覆盖 12 项：

- 旧 schema 1 配置迁移到 schema 2。
- 动态 Account C 配置与快捷键往返。
- 非法 Profile ID/path traversal 被拒绝。
- A/B/C 登录目录相互独立。
- 登录文件原子激活与活动账号标记。
- 第一次切换前保留原官方登录文件备份。
- 切换登录时共享工作区的其他文件保持不变。
- 目标登录缺失时在修改共享状态前失败。
- 删除仅限精确的管理目录，符号链接逃逸被拒绝。
- 日常启动只指向官方默认共享目录，首次登录仍使用账号隔离参数。
- 动态解析实际 5 小时、周窗口、套餐和剩余百分比。
- 忽略 App Server 通知，并丢弃后台账号 ID。

发布流程还会验证 release 构建、应用签名、DMG 挂载内容和 ZIP 内 App 的启动/退出。Release 编译同时使用 Swift `debug-prefix-map` 与 `file-prefix-map`，并在签名前剝离调试符号，避免将构建机用户名及源码/对象文件绝对路径写入发布二进制。

## 风险与边界

| 风险 | 处理 |
|---|---|
| 运行中替换登录文件 | 必须先等待 ChatGPT 完全退出 |
| 切换中断 | 目标文件使用同目录临时文件原子替换；活动标记在替换成功后写入 |
| 原登录被覆盖 | 第一次受管切换前保存一次私有备份 |
| 登录文件异常或符号链接 | 拒绝切换 |
| 删除误伤共享项目 | 删除目标严格限制在 GPT Switcher profiles 下；`~/.codex` 永不作为删除目标 |
| ChatGPT 内手动换号 | 工具无法读取页面识别身份；需要用“重新登录”更新对应快照 |
| App 升级改变认证格式 | 重新验证；不兼容时停止切换 |
