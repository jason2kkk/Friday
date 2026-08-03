# Qwen Audio Agent 架构研究

> 复核日期：2026-08-01  
> 复核对象：`QwenAudio/qwen-audio-agent` 主分支提交 `daa804174ac33e9c3117f82eb9a533e65b0269d6`，对应 `v1.2.0` 版本  
> 结论边界：本文描述的是上述提交的源码事实，不把 README、宣传文案或尚未合并的 PR 当作已实现能力。

## 1. 一句话结论

Qwen Audio Agent 和 Friday 有相同的长期方向：让语音成为 AI Agent 的自然入口。但两者当前解决的问题并不相同：

- Qwen Audio Agent 已经形成较完整的“实时语音前台 + 异步任务运行时 + 外部 Agent”架构。
- Friday 已经形成更深入的 macOS 本地上下文与动作层，包括输入框定位、写回、区域截图和原生悬浮交互。
- Qwen Audio Agent 本身没有实现通用 macOS 输入框定位、Accessibility 写回、区域框选或本地动作执行。

因此，Friday 最合理的方向不是改造成 Qwen Audio Agent 的复刻版，而是：

> 保留 Friday 的原生 macOS Context/Input/Action 能力，引入 Qwen 式的 Conversation、Work、Agent Adapter 和 Result Delivery 边界。

## 2. 我实际检查了什么

本次不是只看项目首页，而是检查了以下源码和测试区域：

- `docs/architecture.md`：产品边界、依赖方向、Work 和交付约束。
- `server/src/task/`：任务状态、调度、持久化、通知 claim 与恢复。
- `server/src/voice/`：Realtime 工具、权限转发、结果播报和双工插入时机。
- `server/src/agent/`：协调 Agent、ACP 适配、Session 注册、委托关联和不同后端驱动。
- `server/src/process/`：外部 Agent 进程的启动和权限模式。
- `tui/native/macos-voice-io.swift`：macOS VoiceProcessingIO 音频链路。
- `desktop/src/`：Electron 窗口、权限、内置 Gateway 生命周期与自动更新。
- `web/`、`tui/`、`cli/`：多个客户端如何消费同一 Gateway 协议。
- 全仓库测试：安装依赖、构建并运行全部测试。

验证结果：构建成功，477 个测试全部通过。当前测试主要是单元、协议和本地集成测试，不等同于真实 DashScope、真实 ACP Agent 或真人语音体验的端到端验收。仓库声明的 Node 支持范围是 `^22.22.2 || ^24.15.0 || >=26`，复核环境为 `24.14.0`，略低于声明下限；测试虽通过，但不能把该环境写成官方支持配置。

## 3. 它不是“一个模型直接控制电脑”

它把产品拆成两个清楚的智能层：

```text
Realtime 前台
  负责听、说、简单直接回答、识别是否需要后台工作

Backend Agent
  负责工具、文件、应用、代码、最新信息和多步骤任务
```

用户只感觉自己在和一个助手说话，但后台并不是一个模型包办全部事情。

Realtime 前台公开的工具只有六个：

```text
spawn_thinking
cancel_agent_task
get_agent_task_status
get_current_time
user_memory
respond_agent_permission
```

这个限制很重要。Realtime 只提交一个保守的 `objective`，不会选择：

- 使用哪个 Agent 或子 Agent；
- 创建或继续哪个后台 Session；
- 同步还是异步执行；
- 用什么工具完成；
- 如何拆解步骤。

这些选择全部留给 Backend Agent。这样语音模型可以替换，后台 Agent 也可以替换，两边不会互相知道过多实现细节。

## 4. Work 是整个架构的中心

当用户提出需要工具或多步骤处理的请求时，`spawn_thinking` 立即返回“已接收”，不会等待任务完成。请求随后进入独立的 Work 系统：

```text
queued -> running -> completed
             |
             +-> delegated -> finalizing -> completed

queued/running/delegated/finalizing
             -> cancelling -> cancelled
                            -> failed
```

Work 不是后台 Agent 内部思考步骤的完整镜像，而是一张面向产品的任务收据。它只公开：

- 用户目标；
- 创建、开始和完成时间；
- 对用户有意义的有限进度；
- 待确认权限的安全摘要；
- 最终结果或错误；
- 结果是否已交付。

它不会把 Session ID、子 Agent、原始 reasoning、后端拓扑和内部权限载荷暴露给前台。

调度器同时控制全局并发、单用户并发和串行 lane。当前默认实现允许全局最多 4 个 Work、每个 owner 最多 2 个，并用类似 `coordinator:<owner>` 的 lane 保证同一协调 Session 的请求不发生并发写入。`submissionKey` 用于防止客户端重试造成重复任务。

## 5. 为什么需要固定的协调 Session

每个 owner 和 backend 都有一个稳定协调身份：

```text
<protocol>:<owner>:backend
```

Gateway 保存外部 ACP Agent 的原生 Session ID，以后通过 `session/resume` 恢复。语音 WebSocket 断开、浏览器刷新或用户开启一轮新对话，都不会自动换掉这个后台 Agent 上下文。

协调 Session 收到的不是只有一句转写，而是一个受控信封：

- 最终 ASR 原文，作为用户意图的事实来源；
- Realtime 给出的保守 objective；
- 最近语音上下文；
- 用户记忆；
- 当前任务上下文；
- 时区；
- 客户端工作目录；
- 最终交付格式要求。

协调 Agent 可以自己完成，也可以委托给另一个项目 Session。对于支持外部 MCP 的 ACP Agent，Gateway 提供五个统一 Session 工具：

```text
sessions_list
session_start
session_send
session_status
session_cancel
```

OpenClaw 不接受客户端注入 MCP，因此用它的原生 Session 工具映射同一契约。这个差异被封装在 Adapter 内，不泄露到语音前台。

## 6. 委托不是简单的“再开一个 Agent”

委托后，原 Work 进入 `delegated`。协调 Session 的锁会释放，其他语音请求仍可继续进入协调层；真正执行任务的目标 Session 独立运行。

完成时必须同时匹配：

- 原 Work；
- delegation ID；
- 目标 Session ID；
- 对应的 ACP prompt 完成事件。

只有匹配的结果才能让 Work 完成。旧事件、无关 Session、空结果或繁忙状态都不能误完成当前 Work。任务取消也不是乐观地把状态改成 cancelled，而是先向准确的执行目标确认停止，然后再进入终态。

这套关联机制值得 Friday 借鉴，因为桌面 Agent 最危险的问题之一就是“旧结果落到新任务”或“取消看起来成功、后台其实还在执行”。

## 7. 结果交付比“拿到模型输出”更复杂

Qwen 的另一个强项是把结果生成和结果真正被用户听到分开。

完成的 Work 先成为待通知结果，然后经历：

```text
pending
  -> claimed by one live client
  -> injected into a safe Realtime turn
  -> audio queued
  -> playback started receipt
  -> playback ended receipt
  -> delivered
```

关键规则包括：

- 用户正在说话、当前回复未结束或播放队列未清空时，不插播结果。
- 多个前台同时在线时，用可续租 claim 防止同一结果被重复播报。
- `response.done` 只表示模型生成结束，不表示用户已经听到。
- 客户端实际开始播放后才确认交付；缺少回执会有限重试。
- 用户打断播报只终止当前播报，不取消已经完成的 Work。
- 一个坏结果经过有限重试后会被放弃，不能阻塞后面的结果。
- 旧回执通过 response/turn 关联和 tombstone 被忽略。

Friday 目前的即时 Talk 不需要完整复制这套分布式通知机制，但未来 Agent 的后台任务必须拥有类似的 `Delivery` 状态，不能把“模型返回”和“用户已收到”混为一谈。

## 8. 权限设计的优点与不足

权限请求绑定 owner、Work 和当前待授权项。Realtime 只能转发用户本轮明确说出的同意或拒绝，不能自己创造授权。

当前公开决策只有：

```text
always
reject
```

`always` 实际上是有时限的 Session 范围自动允许，默认约 6 小时。Qwen 自己提供的 Session MCP 工具可以按策略自动允许。不同 ACP 后端的 full permission 模式会被各自映射，不安全或不支持时直接拒绝。

这套“权限必须与任务关联”的方向是对的，但 Friday 不应直接复制只有 `always/reject` 的粗粒度体验。桌面动作至少需要：

```text
allow_once
allow_for_session
reject
```

并且发送、删除、购买、提交、系统权限变化等高风险动作仍应逐次确认。

## 9. 音频实现为什么值得单独研究

macOS TUI 不是简单把麦克风和扬声器各开一个流，而是使用原生：

```swift
kAudioUnitSubType_VoiceProcessingIO
```

它把：

- Bus 0 的播放作为远端回声参考；
- Bus 1 的采集作为回声消除后的麦克风；
- VoiceProcessingIO 内部统一为 48 kHz；
- 输入再转换为 16 kHz；
- 输出从 24 kHz 转换到内部格式。

播放回调真正从队列消费样本时才发出 `playback.started` / `playback.ended`。这既改善回声消除，也为结果交付提供可信回执。

但需要准确区分：这套实现用于 macOS TUI helper。Electron Desktop 使用浏览器 `getUserMedia` 的 echo cancellation、noise suppression 和 auto gain，不代表所有 Qwen 客户端都享有同样的原生音频质量。

Friday 已参考这一边界实现独立的 `VoiceProcessingAudioUnit`，但没有照抄 Qwen 的完整 helper：Friday 保持 24 kHz Realtime 传输格式，在本地以 48 kHz 连接播放参考和消回声麦克风，并在上层增加自适应近场输入门。VoiceProcessingIO 无法启动时降级为播放期间不上行麦克风的安全半双工。真实 Mac 已验证采集、播放与连续重启；“完整播放、自然插话、不被远处声音误触发”仍需真人声学验收。

## 10. 持久化与恢复

当前实现使用本地 JSON，不是数据库：

- 任务、记忆、Session 注册和通知状态分别持久化；
- 写入采用临时文件替换，文件模式为 `0600`；
- 目录使用 `0700`；
- 损坏存储会被隔离，不直接覆盖；
- activity 列表限制为 20 条；
- 终态结果只保留有限历史；
- Gateway 重启后，普通 active Work 会明确失败；
- 只有带完整 delegation/session 标识且 Adapter 支持恢复的 delegated Work 才可能重新关联。

这是务实的本地产品方案：它没有假装所有进行中任务都能恢复。Friday 应借鉴其明确失败语义；但 Friday 还要关联 Conversation、Memory、Work 和 Delivery，因此目标存储改用本地 SQLite，而不是复制多个 JSON 文件。

## 11. 记忆与上下文的实际实现

Qwen 的记忆系统是保守的文件存储和有限检索，不是自动保存全部聊天的向量记忆系统。

### 两种持久记忆

```text
USER.md
└── profile：称呼、语言、时区和稳定交互偏好

frontend-memory.json
└── long_term：明确希望跨会话保留的事实、喜好、目标和约定
```

`USER.md` 的手写基础内容对模型只读；Qwen 只修改带标记的托管区域。源码限制为：

- 整个 Profile 最多 6000 字符；
- 托管区域最多 32 条；
- 单条最多 500 字符。

`frontend-memory.json` 按 owner 隔离：

- 每个 owner 最多 32 条；
- 单条最多 500 字符；
- 内容生成稳定 SHA-256 ID；
- 检索使用 key/value 的关键词和子串匹配，不使用 embedding；
- 支持 `recall`、`remember`、`replace` 和 `forget`。

记忆写入前使用正则拒绝密码、Secret、API Key、Access Token、Credential、验证码和 `sk-...`。文件使用临时文件替换和 `0600` 权限，损坏 JSON 会隔离；内容仍然是明文，不是 Keychain 密钥加密。

需要保留意见：当前代码会对 `forget` 检查本轮最终转写中是否存在明确删除意图，但 `remember` 和 `replace` 主要依靠工具描述、Prompt 和敏感内容过滤，没有同等级的代码层确认状态。Friday 因此应增加 `proposed -> confirmed`，而不是直接复制。

### 近期会话上下文

`ConversationSync` 按 `ownerId + voiceSessionId` 隔离，完全保存在进程内存：

- 每个会话最多 100 条消息；
- 最多 500 个会话；
- 默认约 6 小时未访问后过期；
- 按消息 ID 去重，并关联 Turn 和 Task；
- 已经播报过的 Agent 结果会被过滤，避免重复注入。

因此它可以在同一 Gateway 进程中帮助 Realtime 重连，但 Gateway 重启后普通近期对话不会恢复。这不是完整的跨天 Conversation Store。

### 每次实际交给模型的内容

Realtime 启动时，`frontend-agent-context.mjs` 最多选择：

- 20 条用户记忆；
- 最近 10 条对话，总计约 3500 字符；
- 5 个活跃任务；
- 当前待授权摘要；
- 时区、语言、会话时间和 TUI 工作目录。

创建后台 Work 时，Coordinator 信封包括：

- 最终 ASR，作为用户原话的事实来源；
- Realtime 整理出的保守 objective；
- 用户记忆；
- 最近 10 条语音上下文，每条最多约 1000 字符；
- 最多 10 个任务摘要；
- owner、voice session、turn 和 request ID；
- 工作目录、时区和交付要求。

记忆、近期对话、工作目录和任务状态都被明确标记为数据，不是系统指令；与当前用户请求冲突时，以当前请求为准。

这个实现最值得借鉴的是分类、限制和优先级，而不是检索算法。它没有自动滚动摘要、语义检索或完整跨重启对话恢复。Friday 需要在该边界上增加 Conversation Store、滚动摘要、可确认 Memory 和加密存储。

## 12. Desktop 的实际边界

`v1.2.0` 的桌面端是 Electron 浮窗，主要能力是：

- 172 x 170 透明置顶窗口；
- 只批准音频 media 权限；
- 自动启动 loopback Gateway，意外退出最多重启 3 次；
- 检测本机已安装的 Agent 后端；
- 签名更新与差分下载；
- renderer sandbox、context isolation 和 loopback 代理限制。

全仓库产品代码搜索没有找到以下原生桌面能力：

```text
AXUIElement / AXIsProcessTrusted
ScreenCaptureKit
CGEvent
NSPasteboard
focused input discovery
screen-region selection
```

也就是说，它对“屏幕上”“当前页面”的处理主要是把请求交给选中的外部 Agent，最终能否理解或操作取决于外部 Agent 自己的工具。它不是一个完整的 macOS Context/Action 层。

还发现一处文档与代码冲突：`docs/architecture.md` 规定客户端不应管理 Gateway，关闭 UI 不影响任务；但 `desktop/src/main.mjs` 明确让 Desktop 拥有本地 Gateway，并在退出时停止该进程。对嵌入式 Desktop 路径而言，关闭客户端确实会影响本地进行中的 Work。Friday 设计不能只复制文档理想，需要明确区分开发期内置服务和正式独立服务的真实生命周期。

## 13. 安全和项目成熟度判断

已验证的安全措施：

- 默认只监听 loopback；
- same-origin 与 DNS rebinding 防护；
- 远程访问要求受允许的 HTTPS 反向代理；
- 浏览器身份使用签名、HttpOnly、SameSite Cookie；
- 默认无遥测；
- 不自动加载远程媒体；
- 配置和持久化文件使用受限权限。

需要保留意见的部分：

- API Key 保存在权限为 `0600` 的明文配置文件，不是系统钥匙串；Friday 当前 Keychain 方案更适合 macOS 原生产品。
- 当前运行时只真正注册 DashScope/Qwen，尽管 Provider 与协议接口已存在。
- 未合并 PR 正在继续调整第二家 speech-to-speech Provider 的能力标记，说明该抽象仍在演进。
- 主要提交高度集中于一位贡献者，架构清晰但项目仍年轻，不能把它视作经过多年、多团队验证的通用标准。

## 14. Friday 应借鉴什么

直接借鉴的原则：

1. Realtime 只负责自然交互和提交 Work，不掌握 Agent 内部拓扑。
2. 所有长任务都进入统一 Work 状态机，而不是挂在某个 SwiftUI View 或语音 Response 上。
3. 一个用户拥有稳定的协调 Agent Session，语音会话只是入口，不是后台记忆身份。
4. 每个 Work、Response、Permission、Action 和 Delivery 都必须可关联、可去重、可取消。
5. 任务完成和结果真正交付必须分开记录。
6. 前台显示有限、可理解的进度，不暴露 reasoning 和内部 Session。
7. 重启恢复只承诺有证据可恢复的状态；其余明确失败。
8. 音频播放需要真实回执，不能只依赖模型的 `response.done`。

Friday 必须保留并继续加强的差异：

1. 原生 Accessibility 输入目标和可靠写回。
2. 用户主动触发的区域屏幕上下文。
3. macOS Keychain 与原生权限引导。
4. Dictate 低延迟直达，不经过重型 Agent。
5. 本地动作执行器和分级确认，不能把所有桌面操作交给编程 Agent 猜测。

## 15. Friday 不应照搬什么

- 不让用户先安装 Codex、Claude Code 或其他编程 Agent 才能使用基础听写、对话和屏幕理解。
- 不把输入框定位、剪贴板、点击或屏幕捕获寄托于外部 Agent 的偶然能力。
- 不把 Qwen 的 Electron 外壳替换 Friday 的 Swift/AppKit 原生层。
- 不把后台 Work 强行放入 Realtime 会话生命周期。
- 不在没有 `allow_once` 和动作预览时引入高风险自动操作。
- 不复制 Qwen 的明文 Key 文件方案。
- 不一次性移植完整 ACP 与多后端矩阵；先用一个可验证 Adapter 打通最小闭环。

## 16. 证据链接

- [复核提交](https://github.com/QwenAudio/qwen-audio-agent/tree/daa804174ac33e9c3117f82eb9a533e65b0269d6)
- [架构文档](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/docs/architecture.md)
- [Work Manager](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/task/task-manager.mjs)
- [Announcement Manager](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/voice/announcement-manager.mjs)
- [ACP Adapter](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/agent/acp-adapter.mjs)
- [macOS VoiceProcessingIO helper](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/tui/native/macos-voice-io.swift)
- [Electron Desktop main process](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/desktop/src/main.mjs)
- [Frontend memory store](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/conversation/frontend-memory.mjs)
- [User profile](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/conversation/user-profile.mjs)
- [Conversation sync](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/conversation/conversation-sync.mjs)
- [Frontend context assembler](https://github.com/QwenAudio/qwen-audio-agent/blob/daa804174ac33e9c3117f82eb9a533e65b0269d6/server/src/conversation/frontend-agent-context.mjs)
