import SwiftUI

/// 轻量 Markdown 渲染（针对总结模板生成的结构：## 标题 / - 列表 / - [ ] 待办 / 段落）
struct SummaryMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.title3.weight(.semibold))
                        .padding(.top, 8)
                case .checkItem(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "square")
                            .foregroundStyle(.secondary)
                        Text(text)
                            .textSelection(.enabled)
                    }
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(text)
                            .textSelection(.enabled)
                    }
                case .paragraph(let text):
                    Text(text)
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(String)
        case bullet(String)
        case checkItem(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let s = String(line)
            if s.hasPrefix("## ") {
                return .heading(String(s.dropFirst(3)))
            } else if s.hasPrefix("- [ ] ") {
                return .checkItem(String(s.dropFirst(6)))
            } else if s.hasPrefix("- ") {
                return .bullet(String(s.dropFirst(2)))
            } else {
                return .paragraph(s)
            }
        }
    }
}
