import AVFoundation

/// PCM buffer 拷贝工具：tap 回调中的 buffer 会被系统复用，
/// 交给下游（如语音识别）前必须拷贝
enum BufferCopy {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copied = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: buffer.frameLength) else {
            return nil
        }
        copied.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copied.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = buffer.int16ChannelData, let dst = copied.int16ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = buffer.int32ChannelData, let dst = copied.int32ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else {
            return nil
        }
        return copied
    }
}
