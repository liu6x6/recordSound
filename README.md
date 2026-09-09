# VoiceScribe

macOS 本地录音 + AI 转写总结助手（麦克风 + 系统声音双轨，全本地 AI 处理）。

📄 设计文档：[docs/DESIGN.md](docs/DESIGN.md)

## 当前状态：Spike 0 — 音频采集可行性验证

### 运行

```bash
brew install xcodegen        # 首次
xcodegen generate            # 生成 VoiceScribe.xcodeproj
open VoiceScribe.xcodeproj   # Xcode 中 Cmd+R 运行
# 或直接命令行构建：
xcodebuild -project VoiceScribe.xcodeproj -scheme VoiceScribe -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/VoiceScribe.app
```

### Spike 0 验证清单

| # | 验证项 | 步骤 | 预期 |
|---|--------|------|------|
| 1 | 麦克风权限 | 首次点"请求授权" | TCC 弹窗，允许后状态变 ✅ |
| 2 | 屏幕录制权限 | 点"刷新权限状态" 触发 | 弹窗或引导去系统设置，授权后 ✅（**授权后需重启 App**） |
| 3 | 麦克风采集 | 勾选麦克风 → 开始录音 → 说话 | 绿色电平条跳动 |
| 4 | 系统声音采集 | 勾选系统声音 → 播放任意视频/音乐 | 电平条随音量跳动，本 App 自身声音不被录入 |
| 5 | 双轨写盘 | 停止录音 → 播放 mic.caf / system.caf | 两轨内容正确、可播放 |
| 6 | 时间轴对齐 | 播放视频同时拍手一次 → 对比两轨波形 | 对齐误差 <200ms |

录音文件位置：`~/Library/Application Support/VoiceScribe/SpikeSessions/<时间戳>/`

### 目录结构

```
App/                 # Spike UI（VoiceScribeApp / SpikeView / SpikeViewModel）
Core/AudioKit/       # MicCapture(AVAudioEngine) / SystemAudioCapture(ScreenCaptureKit)
docs/                # 设计文档
project.yml          # XcodeGen 工程定义
```

### 已知说明

- 系统声音捕获使用 ScreenCaptureKit（`capturesAudio: true`），视频通道以 2x2 最小化但无法完全关闭
- 屏幕录制授权后必须**完全退出并重启 App** 才能生效
- 独立分发路线：当前未开启 App Sandbox；正式签名用 Developer ID + 公证
