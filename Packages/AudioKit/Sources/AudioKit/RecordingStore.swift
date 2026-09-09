import Foundation

/// 录音文件存储管理（独立分发：无沙盒，直接存 ~/Library/Application Support）
public enum RecordingStore: Sendable {

    public static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceScribe/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func directory(for id: UUID) -> URL {
        let dir = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func micFileURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("mic.caf")
    }

    public static func systemFileURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("system.caf")
    }

    /// 删除某个录音的全部音频文件
    public static func deleteFiles(for id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// 轨道文件是否存在且非空（> header 大小）
    public static func hasAudio(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 8_192   // CAF header + 少量数据
    }
}
