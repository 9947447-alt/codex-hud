# CodexHUD

A lightweight real-time Codex token HUD for macOS.

CodexHUD 是一个 macOS 原生悬浮 HUD，用于旁观 Codex Desktop 当前任务的 Token 用量、可见文本输出速度和运行状态。它是独立项目，并非 OpenAI 官方产品。

## Features

- 显示当前任务的 `TASK` Token、模型与 effort。
- 显示可见文本输出速度估算 `≈ tok/s`。
- 显示 generating、running command、running tool、idle、completed 和 disconnected 状态。
- 220×88 悬浮窗口，可拖动、保持置顶，不抢占输入焦点，适应浅色与深色外观。

## Requirements / Current support

- macOS 14 或更高版本。
- Swift 6.0 或更高版本的工具链（Xcode 或 Command Line Tools）。
- 在同一 macOS 用户下运行 Codex Desktop，并能读取其默认 `~/.codex` 本地数据与 IPC socket。

当前明确支持 **Codex Desktop**。已验证环境为 `/Applications/ChatGPT.app` 26.930.31730（build 12947），内置 Codex 0.160.0；其他版本的兼容性未经保证。

当前不支持 Terminal Codex CLI、作为独立目标的 VS Code extension、Windows 或 Linux。

## Build / Run

在仓库根目录执行：

```sh
swift test
swift build -c release
./scripts/package-app.sh
open .build/CodexHUD.app
```

打包脚本将 release executable 和离线 tokenizer 资源复制到 `.build/CodexHUD.app`，不安装应用。当前包未签名、未公证。运行 Codex Desktop 并开始任务后，HUD 自动选择最近开始的活跃主任务；拖动窗口调整位置，右键菜单选择 **Quit** 退出。

也可在终端运行 release executable：

```sh
.build/release/CodexHUD
# 可选：向 stderr 输出元数据诊断
.build/release/CodexHUD --diagnostics
```

## How it works

CodexHUD 增量读取 `~/.codex/sessions` 的 rollout，获取 session / turn 生命周期和权威 Token 用量；从 `~/.codex/archived_sessions` 恢复关联子任务用量。Codex Desktop 私有本地 IPC 提供实时可见文本与命令/工具状态。HUD 注册当前 conversation 的临时 observer following，在切换和正常退出时解除；它不启动、恢复、引导或中断任务，也不改变 task owner。

### TASK Token

`TASK` 以当前 Codex Desktop **`turn_id`** 为边界：

`父 turn 的 turn_token_usage.total_tokens + 可靠关联 child turns 的累计用量高水位之和`

父 turn 用量来自 rollout 权威记录。子记录必须通过 `root_turn_id` 关联当前父 turn；每个 `(thread_id, turn_id)` 只取已观察到的最高累计值，避免重复相加。S1 实测父 turn 总量不包含 child-agent usage，因此需要单独聚合子任务用量。开启新 turn 后不会带入上一任务的 child 用量。

`TASK` 不是 thread 总量、账单总量或 OpenAI 账户用量；它随本地遥测记录更新，并受已观察到的数据和容量限制影响。

### Live speed: `≈ tok/s`

Desktop IPC 的 accepted visible text → 本地离线 `o200k_base` tokenizer → 约 3 秒的单调时钟滑动窗口 → `≈ tok/s`。

这是对**可见文本输出速度的本地估算**。只计入 agent message 的有效新插入文本；snapshot 历史、hidden reasoning、输入和工具输出不计入速度。工具运行阶段清空速度窗口，约 3 秒无文本后显示 `— tok/s`。

`o200k_base` 目前不是 Codex 官方公开的 model-tokenizer mapping，且窗口只观察本地收到的文本，所以它不是精确计费 Token 吞吐、hidden reasoning 吞吐或 OpenAI 服务端权威实时 Token 速率。

## Privacy

所有处理在本机完成。CodexHUD 不上传 session 内容、源代码、prompts 或 Token telemetry；运行时只使用本地文件和本地 Unix socket，不调用远程服务。

可见文本只用于瞬时 IPC 解析与有界 tokenizer 缓冲，不写入文件或日志。可选 `--diagnostics` 会向 stderr 输出状态、thread/turn ID、Token 数、速率和事件计数，不输出 prompt、response 或工具文本；分享诊断前应检查其中的标识符。窗口位置保存在本地用户偏好中。

## Known limitations

- Codex Desktop IPC / telemetry 是私有实现细节，并非稳定公开 API；Codex 升级可能改变兼容性。当前主要支持上述已验证的 Desktop 版本与行为。
- `≈ tok/s` 是可见输出估算，tokenizer mapping 也不构成模型精确计数承诺。
- 只旁观一个当前主任务；多个活跃主任务按开始时间选择，不提供手动任务选择。
- IPC 不可用时，rollout `TASK` 计数仍可显示，实时速度显示 `—`。权威用量出现前也可能没有 `TASK` 数值。
- watcher 和 child ledger 有有界容量：每个 watcher/root 最多 64 个 task watcher 加 4 个 metadata/partial watcher；child ledger 最多 4096 项。超出容量可能无法持续追尾或保留全部子任务用量。

协议、计数边界、资源来源与容量细节见 [docs/TELEMETRY.md](docs/TELEMETRY.md)。

## License

本仓库中的 CodexHUD 代码以 [MIT License](LICENSE) 发布。

随包的 `o200k_base` tokenizer ranks 保留上游许可声明：`Sources/CodexHUDCore/Resources/o200k_base.LICENSE`。项目许可不替换该声明。
