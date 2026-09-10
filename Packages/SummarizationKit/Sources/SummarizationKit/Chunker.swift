import Foundation

/// 长转写分块器：端侧模型上下文有限（约 4K token），
/// 按字符预算在换行/句号处切块，供 map-reduce 使用
public enum Chunker {

    /// 把文本切成 ≤ maxChars 的块，优先在换行处断开
    public static func split(_ text: String, maxChars: Int = 1200) -> [String] {
        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        var current = ""

        // 按行累积（转写文本每段一行）
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            if current.count + lineStr.count + 1 <= maxChars {
                current += (current.isEmpty ? "" : "\n") + lineStr
            } else {
                if !current.isEmpty { chunks.append(current) }
                // 单行超长 → 按句再切
                if lineStr.count > maxChars {
                    chunks.append(contentsOf: splitLongLine(lineStr, maxChars: maxChars))
                    current = ""
                } else {
                    current = lineStr
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func splitLongLine(_ line: String, maxChars: Int) -> [String] {
        var result: [String] = []
        var start = line.startIndex
        while start < line.endIndex {
            let remaining = line[start...]
            if remaining.count <= maxChars {
                result.append(String(remaining))
                break
            }
            // 在 maxChars 范围内找最后一个句末标点
            let searchEnd = line.index(start, offsetBy: maxChars)
            let window = line[start..<searchEnd]
            let cutPoint: String.Index
            if let lastSentenceEnd = window.lastIndex(where: { "。！？.!?；;".contains($0) }) {
                cutPoint = line.index(after: lastSentenceEnd)
            } else {
                cutPoint = searchEnd
            }
            result.append(String(line[start..<cutPoint]))
            start = cutPoint
        }
        return result
    }
}
