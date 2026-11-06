#if os(macOS)
import Foundation

enum Diff {
    static func render(old: String, new: String) -> String {
        if old == new { return "No changes since the previous state of this app." }
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        if n * m > 9_000_000 { return new }
        var lcs = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * w + j] = a[i] == b[j] ? lcs[(i + 1) * w + j + 1] + 1 : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] { i += 1; j += 1 }
            else if i < n && (j == m || lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) { out.append("- " + a[i]); i += 1 }
            else { out.append("+ " + b[j]); j += 1 }
        }
        if out.count * 2 > m { return new }
        return "Changes since the previous state (unchanged lines omitted; their indexes are unchanged):\n" + out.joined(separator: "\n")
    }
}
#endif
