# CodexHUD S1

CodexHUD 是一个原生 macOS 悬浮 HUD，显示当前 Codex Desktop 任务的模型与 effort、TASK token 总量、可见输出速度估算，以及命令/工具状态。

使用系统 Swift 工具链构建、测试并打包：

    swift build
    swift test
    ./scripts/package-app.sh
    open .build/CodexHUD.app

打包脚本只在仓库的 .build 目录生成 CodexHUD.app，不安装应用。release executable 加参数 --diagnostics 可向 stderr 输出仅含元数据的诊断；不会输出 prompt、response 或工具文本。

HUD 增量读取 Codex 本地 session rollout 文件，并通过 Codex Desktop 私有本地 IPC 旁观当前 conversation。它不会启动、恢复、引导、中断 Codex task，也不会更改 task owner。协议与计数含义见 [docs/TELEMETRY.md](docs/TELEMETRY.md)。
