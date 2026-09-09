import SwiftUI
import CoreModels

/// 转写气泡：麦克风（我）靠右蓝色 / 系统声音（对方）靠左紫色，点击跳转播放
struct TranscriptBubble: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onSeek: () -> Void

    private var isMic: Bool { segment.channel == .mic }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMic { Spacer(minLength: 60) }

            VStack(alignment: isMic ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: isMic ? "person.fill" : "speaker.wave.2.fill")
                    Text(isMic ? "我" : "对方")
                        .fontWeight(.semibold)
                    Button {
                        onSeek()
                    } label: {
                        Text(timeString(segment.start))
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(isMic ? .blue : .purple)

                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isMic ? Color.blue.opacity(0.12) : Color.purple.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isActive ? (isMic ? Color.blue : Color.purple) : .clear,
                                          lineWidth: 1.5)
                    )
            }

            if !isMic { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .contentShape(Rectangle())
        .onTapGesture { onSeek() }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
