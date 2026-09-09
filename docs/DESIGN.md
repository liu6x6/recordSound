# VoiceScribe — macOS 录音转写助手 设计文档

> 版本：v0.2（决策已确认）
> 平台：macOS 15+（开发环境 macOS 26 / Xcode 27 / Swift 6）
> 技术栈：SwiftUI + AVFoundation + ScreenCaptureKit + 本地 AI（Speech / FoundationModels / Whisper）
> 分发方式：**独立分发**（Developer ID 签名 + 公证，不上 Mac App Store）

---

## 0. 已确认的产品决策

| # | 决策项 | 结论 |
|---|--------|------|
| 1 | App 名称 | **VoiceScribe** |
| 2 | 录音范围（M1） | **麦克风 + 全部系统声音**（双轨）；按指定 App 精确捕获放到后续迭代探索 |
| 3 | 分发方式 | 独立分发（Developer ID + notarization），沙盒策略可放宽，无需 MAS 审核限制 |
| 4 | AI 引擎 | **默认全本地模型**（对标 iOS 备忘录的端侧体验）：Apple Speech（on-device ASR）+ FoundationModels（端侧 LLM 总结）；Whisper 本地大模型作为高质量可选项；云端 API 不做/仅远期考虑 |

---

## 1. 产品概述

一款类似"会议助手"的 macOS 原生应用，核心能力：

1. **麦克风录音** — 录制系统当前输入设备的声音（"我说的话"）
2. **系统声音录音** — 录制其他 App 播放的声音（"对方的话"：会议软件、浏览器等）
3. **本地 AI 转写 + 总结** — 端侧语音转文字，端侧 LLM 生成会议纪要/笔记，**数据不出设备**

典型场景：会议记录、网课/直播笔记、访谈整理。

### 1.1 非目标（本期不做）

- iOS 版本（架构预留复用能力，后续迭代）
- 按指定 App 精确捕获音频（Process Taps，后续探索）
- 云端 ASR / 云端 LLM（保持"本地优先"，远期可选）
- 屏幕/视频录制、多人协作、云同步

### 1.2 隐私承诺（产品卖点）

- 音频文件、转写文本、总结文档 **全部存储在本地**
- ASR 使用 `SFSpeechRecognizer.requiresOnDeviceRecognition = true`
- 总结使用 `FoundationModels`（Apple Intelligence 端侧模型）
- App 无需网络权限即可完整工作

---

## 2. 技术选型

### 2.1 音频采集

| 音源 | 方案 | 权限 |
|------|------|------|
| 麦克风 | `AVAudioEngine`（inputNode tap，实时 buffer → 波形/流式转写 + 写盘） | 麦克风权限（TCC 弹窗） |
| 全部系统声音 | **ScreenCaptureKit**：`SCStream` 配置 `capturesAudio: true, excludesCurrentProcessAudio: true`，只取音频不取画面 | 屏幕录制权限（TCC，需引导用户去系统设置） |

要点：

- **双轨录制**：麦克风与系统声音各自写入独立音频文件（`mic.caf` / `system.caf`），后期天然区分说话方，混音导出为可选项
- `excludesCurrentProcessAudio: true` 避免自激（录到自己播放的提示音）
- 两路时钟源不同（各自设备采样率/时钟漂移），不做实时硬混音；以各自文件的首个 sample 时间戳对齐，转写时用统一时间轴（相对录音开始时刻）
- 录音中每 5 秒 flush，App 崩溃可恢复
- **后续迭代（探索项）**：Core Audio Process Taps（macOS 14.4+）按 App 捕获。独立分发不受 MAS 限制，但 `com.apple.developer.audio-process-auditing` entitlement 仍需向 Apple 单独申请，故放 M5 探索

### 2.2 本地 AI 能力

#### ASR（语音转文字）— 双引擎策略

| 引擎 | 用途 | 说明 |
|------|------|------|
| **Apple Speech**（on-device） | 录音中**实时流式转写**（字幕即时可见） | `SFSpeechAudioBufferRecognitionRequest`，`requiresOnDeviceRecognition = true`；中文需下载对应语言模型（系统设置 → 键盘 → 听写语言） |
| **Whisper 本地**（可选增强） | 录音结束后**高精度重转写** | 首选 `whisper.cpp`（Core ML / Metal 加速，Apple Silicon 上 small/medium 模型速度可接受）；模型文件用户按需下载（App 内置下载器，模型放 Application Support，不进 App 包） |

流程：实时转写提供"即时反馈"，结束后自动（或手动触发）用 Whisper 重转一遍作为最终稿；用户可在设置里选择只用其中一个引擎。

#### 总结（LLM）

| 方案 | 说明 |
|------|------|
| **FoundationModels 框架**（macOS 26） | Apple Intelligence 端侧模型；`SystemLanguageModel.default` + structured output（`@Generable` 直接生成 摘要/要点/待办 结构体）；免费、私密、无 Key |
| 可用性检测 | `SystemLanguageModel.default.availability`；设备不支持 Apple Intelligence 时：降级显示纯转写稿 + 引导（后续可选：本地 Ollama/MLX 模型接入，作为 M5+ 增强） |
| 长文本 | 端侧模型上下文有限（约 4K token）→ **map-reduce**：转写按 ~3 分钟分段逐段提取要点 → 汇总生成最终纪要 |

总结模板（`@Generable` 结构化输出）：

```swift
@Generable(description: "会议纪要")
struct MeetingNotes {
    @Generable(description: "不超过150字的会议概要") var overview: String
    @Generable(description: "关键讨论点") var keyPoints: [String]
    @Generable(description: "达成的决议") var decisions: [String]
    @Generable(description: "待办事项") var actionItems: [ActionItem]
    @Generable(description: "关键词") var keywords: [String]
}
```

模板类型：会议纪要 / 课程笔记 / 访谈整理（各自不同 schema 与 prompt）。

### 2.3 存储

- **SwiftData**：`Recording` / `TranscriptSegment` / `SummaryDoc` 元数据与文本
- **文件系统**：`~/Library/Application Support/VoiceScribe/Recordings/<uuid>/`
  - `mic.caf`、`system.caf`、`export/`（用户导出的混音/转码）
  - Whisper 模型：`.../Models/ggml-small.bin` 等

---

## 3. 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                     SwiftUI App 层                       │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐ ┌───────────┐  │
│  │ 录音主页  │ │ 录音库   │ │ 转写/详情  │ │  设置页    │  │
│  │ +MenuBar │ │          │ │           │ │           │  │
│  └────┬─────┘ └────┬─────┘ └─────┬─────┘ └─────┬─────┘  │
├───────┼────────────┼─────────────┼─────────────┼────────┤
│       ▼            ▼             ▼             ▼        │
│  ┌─────────────────────────────────────────────────┐    │
│  │            ViewModel 层 (@Observable)            │    │
│  │  RecordingVM · LibraryVM · DetailVM · SettingsVM │    │
│  └─────────────────────┬───────────────────────────┘    │
├────────────────────────┼────────────────────────────────┤
│                        ▼        Core 服务层（本地包）      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐ │
│  │ AudioKit     │ │Transcription │ │ Summarization    │ │
│  │ ·MicCapture  │ │Kit           │ │ Kit              │ │
│  │ ·SystemCaptu │ │ ·SpeechLive  │ │ ·FoundationModel │ │
│  │  re(SCK)     │ │  ASR         │ │  sProvider       │ │
│  │ ·TrackWriter │ │ ·WhisperASR  │ │ ·MapReduce长文    │ │
│  │ ·LevelMeter  │ │ (Provider协议)│ │ ·模板(Generable)  │ │
│  └──────┬───────┘ └──────┬───────┘ └────────┬─────────┘ │
│         ▼                ▼                  ▼           │
│  ┌──────────────┐ ┌──────────────────────────────────┐  │
│  │ FileStore    │ │ SwiftData (CoreModels)            │  │
│  └──────────────┘ └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 3.1 工程结构

```
VoiceScribe/
├── VoiceScribe.xcodeproj
├── App/
│   ├── VoiceScribeApp.swift       # @main, ModelContainer, 场景
│   ├── AppState.swift             # 全局状态（录音会话、权限状态）
│   └── MenuBar/                   # MenuBarExtra 录音控制
├── Packages/
│   ├── CoreModels/                # SwiftData @Model + 枚举
│   ├── AudioKit/
│   │   ├── MicCapture.swift       # AVAudioEngine 封装
│   │   ├── SystemAudioCapture.swift # SCStream 音频封装
│   │   ├── RecordingSession.swift # 编排双轨、计时、flush、崩溃恢复
│   │   └── LevelMeter.swift       # 电平/波形数据源
│   ├── TranscriptionKit/
│   │   ├── TranscriptionProvider.swift # protocol（流式 + 文件两种）
│   │   ├── SpeechLiveProvider.swift
│   │   ├── WhisperProvider.swift  # whisper.cpp 桥接（C++ interop）
│   │   └── ModelDownloader.swift  # Whisper 模型下载管理
│   ├── SummarizationKit/
│   │   ├── SummarizationProvider.swift
│   │   ├── AppleLLMProvider.swift # FoundationModels
│   │   ├── Templates.swift        # 会议纪要/课程/访谈 @Generable
│   │   └── Chunker.swift          # map-reduce 分段
│   └── DesignSystem/              # WaveformView, RecordButton, 状态徽章
├── Features/
│   ├── Record/                    # 录音主页
│   ├── Library/                   # 录音库
│   ├── Detail/                    # 总结/转写/播放 详情
│   └── Settings/                  # 设置
└── Support/
    ├── PermissionCenter.swift     # TCC 权限检测与引导
    └── Exporters/                 # Markdown/PDF/SRT/混音导出
```

### 3.2 数据模型（CoreModels）

```swift
@Model final class Recording {
    var id: UUID
    var title: String               // 默认 "录音 yyyy-MM-dd HH:mm"
    var createdAt: Date
    var duration: TimeInterval
    var micFilePath: String?
    var systemFilePath: String?
    var status: RecordingStatus     // .recording/.processing/.liveDone/.refinedDone/.failed
    var liveEngine: ASREngine       // 实时转写用的引擎
    var finalEngine: ASREngine?     // 精转引擎（whisper/apple/none）
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.recording)
    var segments: [TranscriptSegment]
    @Relationship(deleteRule: .cascade) var summary: SummaryDoc?
}

enum Channel: String, Codable { case mic, system }   // 我 / 对方

@Model final class TranscriptSegment {
    var start: TimeInterval         // 统一时间轴（相对录音开始）
    var end: TimeInterval
    var text: String
    var channel: Channel
    var isFinal: Bool               // 实时转写的中间态 vs 终稿
    var recording: Recording?
}

@Model final class SummaryDoc {
    var generatedAt: Date
    var templateKind: String        // meeting/lecture/interview
    var markdown: String            // 渲染后的正文
    var actionItemsJSON: Data       // 结构化待办
    var keywords: [String]
    var model: String               // "apple-foundation-model" 等
}
```

---

## 4. 功能设计

### 4.1 录音主页

```
┌─────────────────────────────────────────────────┐
│ VoiceScribe                        ● REC 00:12:35│
│                                                 │
│  音源：                                          │
│  [✓] 麦克风   (MacBook Pro 麦克风 ▾)  ▂▃▅▇▅▃▂     │
│  [✓] 系统声音 (对方/其他 App)         ▁▂▃▂▁▂▃     │
│                                                 │
│  实时转写（Apple Speech · 端侧）：                  │
│  ┌───────────────────────────────────────────┐  │
│  │ 对方 00:12:01  好的，那我们下周一再对齐…      │  │
│  │ 我   00:12:08  没问题，我先把文档发出来       │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│        [ ⏸ 暂停 ]      [ ⏹ 结束并生成文档 ]       │
└─────────────────────────────────────────────────┘
```

- **权限引导卡**：麦克风/屏幕录制任一未授权 → 主页顶部黄条提示 + "去授权"按钮（`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` 深链）
- **MenuBarExtra**：录音中可关主窗，菜单栏显示 ●REC + 计时，点击可暂停/停止
- **结束流程**：停止 → 状态 `.processing` →（若启用）Whisper 精转 → 自动触发总结 → 完成通知 → 跳详情页
- 全局热键（可配置）：开始/停止录音

### 4.2 录音库

- 列表行：标题 / 日期 / 时长 / 状态徽章（🔴录音中 · ⏳精转中 · ✨总结完成）/ 双轨图标
- 搜索：标题 + 转写全文（SwiftData `#Predicate`）
- 右键菜单：重命名、导出（混音 m4a / Markdown / SRT / 纯文本）、在 Finder 中显示、删除

### 4.3 详情页

三个 Tab：

1. **总结**：Markdown 渲染的会议纪要；模板切换（会议/课程/访谈）+ 重新生成；待办事项列表可勾选
2. **文稿**：按声道对话气泡（我 / 对方）+ 时间戳，点击跳转播放；支持手动编辑修正文本；"用 Whisper 重新精转"按钮
3. **音频**：双轨波形（可分轨静音播放），进度条联动文稿高亮

### 4.4 AI 流水线（全本地）

```
[录音中]
 mic/system PCM buffer ──► SpeechLiveProvider（on-device 流式）──► 实时字幕（isFinal=false→true）
                       └─► TrackWriter 写盘（caf, 每5s flush）

[结束后]
 mic.caf + system.caf
   ├─（可选）WhisperProvider 分轨精转 ──► 终稿 segments（含时间戳/声道）
   │      · 分轨转写天然得到说话方；whisper.cpp 按 30s 窗口切分
   └─ AppleLLMProvider:
        终稿全文 ──► Chunker（~3min/段）──► 逐段要点提取（map）
                 ──► 汇总生成 MeetingNotes（reduce, @Generable 结构化输出）
                 ──► SummaryDoc 存库 ──► 本地通知"纪要已生成"
```

降级链：Whisper 未下载 → 用 Apple Speech 离线整文件转写；FoundationModels 不可用 → 只交付转写稿并提示。

### 4.5 设置页

- **音频**：输入设备选择、格式（默认 CAF/PCM 16k mono 转写轨 + 48k 存档轨可选）、存储位置
- **转写**：实时引擎开关；Whisper 模型管理（下载/删除：tiny/base/small/medium，显示体积与速度对比）；语言（自动/zh/en/…）
- **总结**：模型可用性状态（Apple Intelligence 是否支持）、默认模板、录音结束后自动生成开关
- **通用**：菜单栏图标、全局热键、外观
- **关于**：隐私说明（"所有 AI 处理均在设备端完成，无网络请求"）

---

## 5. 签名 / 权限 / 分发（独立分发）

| 项 | 配置 |
|----|------|
| 签名 | Developer ID Application + **公证**（notarytool），Staple 票据 |
| App Sandbox | **可不开启**（独立分发无强制）。决策：M1-M4 不开沙盒以便音频/文件访问最简；如需上架 MAS 再评估迁移成本 |
| Hardened Runtime | ✅ 开启（公证必需） |
| Entitlements | `com.apple.security.device.audio-input`（麦克风）；无需网络 entitlement（无网络功能） |
| Info.plist | `NSMicrophoneUsageDescription`："VoiceScribe 需要访问麦克风以录制您的声音" |
| 屏幕录制权限 | ScreenCaptureKit 触发 TCC；首次 `SCShareableContent.current` 调用会弹权限；需检测 `SCShareableContent.excludingDesktopWindows` 失败态并引导 |
| 更新分发 | 后期可接 Sparkle（appcast），M1-M4 手动 DMG |

---

## 6. 开发路线图

| 阶段 | 周期 | 内容 | 验收标准 |
|------|------|------|---------|
| **Spike 0** | 3-5天 | 命令行/demo 验证：① AVAudioEngine 录麦 ② SCStream 只录系统音频 ③ 双文件时间轴对齐可行性 | 录 1 分钟"会议"（本地播放视频+对麦说话），两轨回放对齐误差 <200ms |
| **M1 双轨录音 MVP** | 2周 | 工程骨架（含本地包）、权限引导、录音主页（双轨开关/波形/计时）、TrackWriter+flush、MenuBarExtra、录音库、详情页音频播放 | 完整录一场会议并双轨回放、导出 |
| **M2 实时转写** | 2周 | SpeechLiveProvider（on-device 中文流式）、实时字幕 UI、segments 入库、文稿 Tab（气泡+时间戳+跳播） | 中文会议实时字幕延迟 <2s，结束后可查看/编辑文稿 |
| **M3 Whisper 精转** | 1-2周 | whisper.cpp 集成（SPM/C++ target）、模型下载器、分轨精转、终稿替换实时稿 | 同一段录音，精转准确率明显优于实时稿 |
| **M4 本地总结** | 1周 | AppleLLMProvider、map-reduce Chunker、三套模板（@Generable）、总结 Tab、重新生成、Markdown/待办导出、完成通知 | 一键生成结构化会议纪要（Apple Intelligence 机型） |
| **M5 打磨+分发** | 1-2周 | 全局热键、搜索、导出（PDF/SRT/混音）、崩溃恢复完善、图标/首启体验、Developer ID 签名+公证+DMG | 可对外分发的 v1.0 |
| **M6+ 探索** | — | Process Taps 按 App 录音（entitlement 申请）、说话人分离、iOS 版、Ollama 本地 LLM 备选 | — |

---

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|------|------|------|
| 屏幕录制权限引导失败/用户拒绝 | 录不到系统声音 | 首启分步引导（图文+深链系统设置）；未授权时麦克风单轨仍可用，UI 明确降级状态 |
| Apple Speech 中文 on-device 识别率一般 | 实时字幕质量差 | 定位为"即时预览"，终稿靠 Whisper 精转；设置里说明两者分工 |
| Whisper 模型体积（small ≈ 460MB） | 下载/存储负担 | 不打包进 App，按需下载，默认推荐 small，可换 base（142MB） |
| whisper.cpp C++ 集成复杂度 | M3 延期 | 用官方 swift bindings / C interop 成熟方案；Spike 阶段先跑通命令行 |
| FoundationModels 需 Apple Intelligence（M 系芯片 + 系统语言支持） | 部分用户无本地总结 | `availability` 检测 + 优雅降级（只出转写稿）；M6+ 可加 Ollama 备选 |
| 端侧 LLM 上下文窗口小（~4K） | 长会议总结不全 | map-reduce 分段策略（已设计）；超长录音（>2h）提示分段处理 |
| 双轨时钟漂移导致音画/文稿错位 | 长录音转写时间戳漂移 | 各轨记录起始 host time；精转后按轨独立时间戳，UI 层统一时间轴换算 |
| 长录音文件过大 | 磁盘压力 | 16kHz mono PCM ≈ 115MB/小时，设置里提供"仅存转写用低码率 AAC"选项 + 转写完成后可选删原始音频 |

---

## 8. 下一步

1. 按第 3.1 节创建 Xcode 工程与本地 Swift Package 骨架
2. 执行 **Spike 0**：两个最小验证 target
   - `MicSpike`：AVAudioEngine tap → 写 `mic.caf` + 电平回调
   - `SysSpike`：SCStream(capturesAudio) → 写 `system.caf`，验证权限流程与 `excludesCurrentProcessAudio`
3. 验证通过后合并进 M1 主工程
