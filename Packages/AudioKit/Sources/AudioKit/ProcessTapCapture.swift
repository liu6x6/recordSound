import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - 音频进程信息

public struct AudioProcessInfo: Sendable, Identifiable, Equatable, Hashable {
    /// CoreAudio 进程对象 ID（创建 Tap 用）
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    /// 当前是否正在输出音频（用于 UI 排序标记）
    public let isRunningOutput: Bool

    public var id: AudioObjectID { objectID }
}

// MARK: - 进程枚举（macOS 14.4+ kAudioHardwarePropertyProcessObjectList）

public enum ProcessTapEnumerator {

    /// 列出当前存在音频活动的进程（正在输出的排前面）
    public static func audioProcesses() -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        var mutableSize = size
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &mutableSize, &objects) == noErr else {
            return []
        }

        var result: [AudioProcessInfo] = []
        for obj in objects {
            guard let bundleData = propertyData(obj, kAudioProcessPropertyBundleID),
                  let pidData = propertyData(obj, kAudioProcessPropertyPID) else { continue }

            let bundleID: String = bundleData.withUnsafeBytes { raw in
                let cf = raw.load(as: Unmanaged<CFString>.self).takeRetainedValue()
                return cf as String
            }
            guard !bundleID.isEmpty else { continue }

            let pid = pidData.withUnsafeBytes { $0.load(as: pid_t.self) }
            let runningOut = boolProperty(obj, kAudioProcessPropertyIsRunningOutput)
            let running = boolProperty(obj, kAudioProcessPropertyIsRunning)
            guard running || runningOut else { continue }

            result.append(AudioProcessInfo(objectID: obj, pid: pid, bundleID: bundleID, isRunningOutput: runningOut))
        }
        return result.sorted {
            ($0.isRunningOutput ? 0 : 1) < ($1.isRunningOutput ? 0 : 1)
        }
    }

    private static func propertyData(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Data? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw) == noErr else {
            raw.deallocate()
            return nil
        }
        return Data(bytesNoCopy: raw, count: Int(size), deallocator: .free)
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        guard let data = propertyData(object, selector) else { return false }
        return data.withUnsafeBytes { raw in
            switch raw.count {
            case 1: return raw.load(as: Bool.self)
            case 4: return raw.load(as: UInt32.self) != 0
            default: return false
            }
        }
    }
}

// MARK: - Process Tap 采集

/// 按 App 精确捕获音频输出（macOS 14.2+ Process Taps）
///
/// 流程：CATapDescription(进程列表) → AudioHardwareCreateProcessTap
///      → 创建仅含该 Tap 的私有聚合设备 → AUHAL 从聚合设备拉取 PCM → 写盘
///
/// ⚠️ 探索项：可能需要 `com.apple.developer.audio-process-auditing` entitlement，
/// 失败时抛出 CaptureError.tapCreationFailed(OSStatus) 供上层降级到 SCStream 全局捕获
public final class ProcessTapCapture: @unchecked Sendable {

    public enum CaptureError: LocalizedError {
        case noProcessesSelected
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case audioUnitSetupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noProcessesSelected:
                return "未选择任何 App"
            case .tapCreationFailed(let status):
                return "创建进程音频 Tap 失败（OSStatus \(status)）。可能需要 Apple 授权的 audio-process-auditing entitlement，或缺少屏幕录制权限"
            case .aggregateCreationFailed(let status):
                return "创建 Tap 聚合设备失败（OSStatus \(status)）"
            case .audioUnitSetupFailed(let msg):
                return "音频单元初始化失败: \(msg)"
            }
        }
    }

    private let processObjectIDs: [AudioObjectID]

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private let aggregateUID = "com.voicescribe.tap.\(UUID().uuidString)"
    private var audioUnit: AudioUnit?
    private var avFormat: AVAudioFormat?

    private var file: AVAudioFile?
    private var pendingFileURL: URL?
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.voicescribe.processtap.write", qos: .userInitiated)

    public var onLevel: (@Sendable (Float) -> Void)?
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public private(set) var isRecording = false
    public private(set) var isPaused = false

    // 渲染用持久 ABL（非交错立体声，2 个 buffer）
    private let maxFrames: UInt32 = 8192
    private let ablMemory: UnsafeMutableRawPointer
    private let ch0: UnsafeMutableRawPointer
    private let ch1: UnsafeMutableRawPointer

    public init(processObjectIDs: [AudioObjectID]) {
        self.processObjectIDs = processObjectIDs
        let ablSize = MemoryLayout<AudioBufferList>.stride + MemoryLayout<AudioBuffer>.stride
        ablMemory = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 16)
        ch0 = UnsafeMutableRawPointer.allocate(byteCount: Int(maxFrames) * 4, alignment: 16)
        ch1 = UnsafeMutableRawPointer.allocate(byteCount: Int(maxFrames) * 4, alignment: 16)
    }

    deinit {
        ablMemory.deallocate()
        ch0.deallocate()
        ch1.deallocate()
    }

    // MARK: 生命周期

    public func start(fileURL: URL) async throws {
        guard !processObjectIDs.isEmpty else { throw CaptureError.noProcessesSelected }
        guard !isRecording else { return }

        // 1. 创建进程 Tap（默认 CATapUnmuted：不影响 App 正常发声）
        let tap = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tap.name = "VoiceScribe App Tap"
        tap.isPrivate = true

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tap, &newTapID)
        guard tapStatus == noErr else { throw CaptureError.tapCreationFailed(tapStatus) }
        tapID = newTapID

        // 2. 创建仅含 Tap 的私有聚合设备
        let desc: [String: Any] = [
            "uid": aggregateUID,
            "name": "VoiceScribe App Tap",
            "private": true,
            "stacked": false,
            "taps": [tap.uuid.uuidString],
            "tapautostart": true,
        ]
        var newAggID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            throw CaptureError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAggID

        // 3. AUHAL 拉取
        do {
            try setupAudioUnit(deviceID: aggregateID)
        } catch {
            teardownHalObjects()
            throw error
        }

        lock.withLock {
            file = nil
            pendingFileURL = fileURL
        }

        let startStatus = AudioOutputUnitStart(audioUnit!)
        guard startStatus == noErr else {
            teardownHalObjects()
            throw CaptureError.audioUnitSetupFailed("AudioOutputUnitStart OSStatus \(startStatus)")
        }
        isRecording = true
        isPaused = false
    }

    public func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
    }

    public func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
    }

    public func stop() async {
        guard isRecording else { return }
        isRecording = false
        isPaused = false

        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        teardownHalObjects()

        writeQueue.sync {
            lock.withLock {
                self.file = nil
                self.pendingFileURL = nil
            }
        }
    }

    private func teardownHalObjects() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    // MARK: AudioUnit 设置

    private func setupAudioUnit(deviceID: AudioDeviceID) throws {
        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &compDesc) else {
            throw CaptureError.audioUnitSetupFailed("找不到 HALOutput 组件")
        }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else {
            throw CaptureError.audioUnitSetupFailed("无法创建 AudioUnit 实例")
        }

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                             &enableInput, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                             &disableOutput, UInt32(MemoryLayout<UInt32>.size))

        var device = deviceID
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw CaptureError.audioUnitSetupFailed("无法绑定聚合设备")
        }

        var maxFrames = self.maxFrames
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        // 期望格式：48kHz 立体声 float32 非交错（AU 内部做采样率/格式转换）
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var asbd = format.streamDescription.pointee
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                   &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            throw CaptureError.audioUnitSetupFailed("无法设置流格式")
        }

        var callback = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
            throw CaptureError.audioUnitSetupFailed("无法设置渲染回调")
        }

        guard AudioUnitInitialize(au) == noErr else {
            throw CaptureError.audioUnitSetupFailed("AudioUnitInitialize 失败")
        }
        audioUnit = au
        avFormat = format

        // 预置持久 ABL 结构
        let ablPtr = ablMemory.assumingMemoryBound(to: AudioBufferList.self)
        ablPtr.pointee.mNumberBuffers = 2
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: ch0)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4, mData: ch1)
    }

    // MARK: 渲染回调（RT 线程：只做拷贝，写盘走 writeQueue）

    private static let renderCallback: AURenderCallback = { refCon, actionFlags, timeStamp, _, frameCount, _ in
        let capture = Unmanaged<ProcessTapCapture>.fromOpaque(refCon).takeUnretainedValue()
        return capture.handleRender(actionFlags: actionFlags, timeStamp: timeStamp, frames: frameCount)
    }

    private func handleRender(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let au = audioUnit, frames > 0, frames <= maxFrames else { return noErr }

        let ablPtr = ablMemory.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        let byteSize = frames * 4
        buffers[0].mDataByteSize = byteSize
        buffers[1].mDataByteSize = byteSize

        let status = AudioUnitRender(au, actionFlags, timeStamp, 1, frames, ablPtr)
        guard status == noErr else { return status }
        guard !isPaused, let format = avFormat else { return noErr }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: ablPtr, deallocator: nil),
              let copied = BufferCopy.copy(pcm) else { return noErr }

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.ensureFile(with: copied.format)
                do { try self.file?.write(from: copied) } catch { /* 忽略 */ }
            }
            self.onLevel?(LevelMath.normalized(copied))
            self.onBuffer?(copied)
        }
        return noErr
    }

    private func ensureFile(with format: AVAudioFormat) {
        guard file == nil, let url = pendingFileURL else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings)
    }
}
