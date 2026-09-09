import AVFoundation

/// 电平计算：PCM buffer → 归一化 0~1（40dB 动态范围映射）
public enum LevelMath {
    public static func normalized(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        var count: Int = 0
        for i in stride(from: 0, to: n, by: 4) {
            sum += data[i] * data[i]
            count += 1
        }
        guard count > 0 else { return 0 }
        let rms = sqrtf(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 40) / 40, 0), 1)
    }
}
