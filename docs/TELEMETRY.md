# 遥测与计数语义

CodexHUD 只显示当前 Codex Desktop 主任务。它从 ~/.codex/sessions 增量读取已存在及新建的 rollout JSONL 文件；FSEvents 负责路径发现、目录扫描与替换/移出，per-file vnode `.write/.extend` 监听持久打开的 writer append。每个文件按 identity、offset 与未完成行缓冲，读取上限为每次 256 KiB、单行 1 MiB；只读取新增字节。另一个 watcher 只从 ~/.codex/archived_sessions 恢复已归档的子 agent token 累计值。

每个 watcher/root 最多保留 64 个有 task_started 时间戳的文件 watcher，按最新任务时间优先；另有 4 个独立名额用于尚未解出 task_started 的 metadata/partial 文件，总上限 68。完成 task 不会因定时器自动关闭 watcher，以便继续发现同一文件中的下一 turn；文件移出/删除或被更新任务挤出时才撤销对应 vnode。超过容量的 session 仍可能被初始扫描或路径事件 drain，但容量之外没有 per-file 持续追尾保证；因此实现有明确的多 session 描述符上限，不声称可无限并行旁观。HUD 每 350 ms 更新一次。

## 活跃任务选择

只有 metadata 中 originator == "Codex Desktop"、source == "vscode" 的非 subagent session 能作为主任务候选。Subagent 的 source.subagent 是对象，不能与桌面根 session 混同。候选任务必须仍处于 rollout 的 task_started active 状态；选择 started_at 最新的主任务。该字段是 Unix 秒，解码时安全转换为毫秒。时间相同按 thread ID、turn ID 稳定排序；多个 active 候选中若有缺失时间戳，暂不猜测 winner。

每个文件/inode 生命周期固定首个有效 session_meta 为 canonical identity；fork history 中随后复制的父 metadata 不得覆盖子 session 身份。文件替换或截断后重新建立 identity。

IPC snapshot 中的 threadRuntimeStatus.type == "active" 和 turn status == "inProgress" 是两个独立状态。Runtime idle 且 turn 仍 inProgress 时，HUD 显示 idle，但继续保留该候选和 follower，使同一 turn 后续恢复时仍能接收 patch。Turn status == "completed" 或 rollout 的 task_complete 会将匹配 turn 标记为 complete；即使切换 thread、断线或收到旧 rollout-active 记录，也不会重新入选，直到不同 turn 的权威 task_started。Session archive/removal 会移除候选。断开 IPC 后保留 rollout 模型、TASK、AVG 和 API≈；不把 thread lifetime token 用量当作当前任务用量。

## TASK token

主任务数值直接读取当前 turn 的 token_usage_record.turn_token_usage.total_tokens。这个字段已经包含 cached input 与 reasoning output；禁止再次相加 cached_input_tokens、cache_write_input_tokens 或 reasoning_output_tokens，也不使用 thread_token_usage 的会话累计值。

子 agent 的 token usage 不包含在父 turn 总数里，故 TASK 显示值为父 turn 的 turn_token_usage.total_tokens，加上每个关联子任务 (thread_id, turn_id) 的最高 turn_token_usage.total_tokens。

子记录必须有 root_turn_id == 当前父 turn_id；相同 thread/turn 的累计更新取 high-water mark，而不是把 response 记录相加。父 thread 自身不会被重复加作 child。子 session 移入 archive 后仍保留其已观察到的用量；启动时也扫描 archive，以便 HUD 重启后重建这部分总量。Ledger 按 thread/turn 去重并限制最多 4096 项。父任务开始新 turn 时，查询只匹配新 root_turn_id，不会把上一任务的 child 用量带入。

## AVG

AVG 的分子是当前父 turn 的 `turn_token_usage.output_tokens` 高水位，加上每个关联子 turn 的 `turn_token_usage.output_tokens` 高水位。`output_tokens` 已包含 `reasoning_output_tokens`。分子不是 `total_tokens`，也不使用可见文本 tokenizer、网络字节或假定生成速率。

分母是当前父 turn 的 `task_started.started_at`（Unix 秒，换算成毫秒）到最近一次使该分子增加的用量行 `timestamp`。0.160.0 的用量行带 ISO-8601 时间戳。`usage` 是单次请求用量，`turn_token_usage` 是该 turn 内这些请求的累计值；AVG 使用累计 output，不把同一累计值再加一次。新的结算如果只增加 input、output 不变，AVG 保持不变。起点、结算时间或 output 字段缺失，或时长小于等于 0，都显示 `— tok/s`。

## API≈

API≈ 是捆绑的 2026-10-05 OpenAI Standard API 标价等价估算，不是 Codex Desktop 或 ChatGPT 的实际账单。它只给 `usage` 里单次请求的分项计价：ordinary input、cached input、cache write input 和 output。不给 `total_tokens` 或 turn 累计值直接计价，因此不会把累计 input 误当成一次长上下文请求。

长上下文门槛是单次 `usage.input_tokens > 272000`。`cached_input_tokens` 缺失则该请求不可计价；`cache_write_input_tokens` 缺失按 0。模型来自该 turn 的 `turn_context.model`，子 turn 用自己的模型。未知模型、模型冲突、分项不自洽，或任一材料用量无法计价时，整个任务显示 `API≈—`。`thread_settings.service_tier` 可见为 default 或 priority，但不换算成其它计费倍率。

已捆绑的模型 ID：`gpt-6.1-sol`、`gpt-6-sol`、`gpt-6-luna`、`gpt-6-astra`。价目随二进制打包，运行时不访问网络。

## 可见文本

桌面 IPC 的 accepted visible text 仍用于判断最近是否有 agent message，从而驱动 generating 状态点。它不产生 HUD 上的 tok/s。隐藏 reasoning 在这条已测试的链路上没有增量 token 流。

token 文本计数如果仍被内部缓冲使用，使用随包离线 `o200k_base` ranks。资产来源为 [OpenAI tiktoken o200k_base definition](https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py) 指向的 [canonical ranks file](https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken)，SHA-256 为 446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d。显示文本限于当前 IPC frame 的瞬时解析和有界 token tail，不写入文件或日志。

## 桌面 IPC 边界

本机观察验证的桌面 app 为 /Applications/ChatGPT.app，版本 26.930.31730、build 12947，内置 Codex 0.160.0。HUD 连接 ~/.codex/ipc/ipc.sock，使用 4-byte little-endian 长度前缀与 UTF-8 JSON。私有协议只使用 initialize 获取 observer clientId，以及 thread-stream-following-changed 为选中的本机 conversation 临时设置 following true；切换或正常退出时发送 false。HUD 接收 thread-stream-state-changed v11 snapshot/patch 通知，并读取 acceptedTextChanges。

HUD 不发送 owner 或 state 改变、thread-follower 控制、resume、start、steer 或 interrupt 请求；socket 断开会清除连接内临时 follower 并重连。Snapshot 实际活跃 turns 位于 turnHistory.history.entitiesByKey；空 turns 数组不能代表无活跃 turn。若 patch revision 缺口或出现结构性未知字段，HUD 重新获取 snapshot，不猜补漏。

该 IPC 是未公开的内部协议，不是兼容性承诺。记录的通知 version、schema、socket path 与 app/Codex 版本必须在升级后重新验证。若协议不可用，rollout 的 TASK、AVG 和 API≈ 仍可按已结算记录显示。

## 可选诊断

--diagnostics 只向 stderr 输出状态、thread/turn ID、父与子任务 token 数、TASK 行、AVG、API 等价估算、monotonic uptime、事件/patch 计数与 revision gap 计数。诊断不会输出真实 prompt、response、agent text、tool output 或整份 rollout JSONL。
