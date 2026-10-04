import Foundation

public protocol TokenCounter {
    func countTokens(in text: String) -> Int
}

public enum O200kTokenizerError: Error {
    case missingResource
    case invalidResource
    case invalidPattern
}

// The rank table is immutable after initialization, and NSRegularExpression is immutable/thread-safe.
public final class O200kTokenizer: TokenCounter, @unchecked Sendable {
    private static let pretokenPattern = [
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
        #"\p{N}{1,3}"#,
        #" ?[^\s\p{L}\p{N}]+[\r\n/]*"#,
        #"\s*[\r\n]+"#,
        #"\s+(?!\S)"#,
        #"\s+"#,
    ].joined(separator: "|")

    private let ranks: [Data: Int]
    private let pretokenizer: NSRegularExpression

    public convenience init() throws {
        guard let url = Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken") else {
            throw O200kTokenizerError.missingResource
        }
        try self.init(ranksData: Data(contentsOf: url))
    }

    public init(ranksData: Data) throws {
        guard
            ranksData.count <= 4_500_000,
            let encodedRanks = String(data: ranksData, encoding: .utf8),
            let expression = try? NSRegularExpression(pattern: Self.pretokenPattern)
        else {
            throw O200kTokenizerError.invalidPattern
        }

        var parsedRanks: [Data: Int] = [:]
        parsedRanks.reserveCapacity(199_998)
        for (expectedRank, line) in encodedRanks.split(whereSeparator: \.isNewline).enumerated() {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard
                fields.count == 2,
                let bytes = Data(base64Encoded: String(fields[0])),
                let rank = Int(fields[1]),
                rank == expectedRank,
                parsedRanks[bytes] == nil
            else {
                throw O200kTokenizerError.invalidResource
            }
            parsedRanks[bytes] = rank
        }
        guard parsedRanks.count == 199_998 else { throw O200kTokenizerError.invalidResource }

        ranks = parsedRanks
        pretokenizer = expression
    }

    public func countTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = pretokenizer.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return bytePairCount(Data(text.utf8)) }

        var tokenCount = 0
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let count = bytePairCount(Data(text[range].utf8))
            let (sum, overflow) = tokenCount.addingReportingOverflow(count)
            tokenCount = overflow ? Int.max : sum
        }
        return tokenCount
    }

    private func bytePairCount(_ bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }
        if ranks[bytes] != nil { return 1 }
        var pieces = bytes.map { Data([$0]) }
        while pieces.count > 1 {
            var bestIndex: Int?
            var bestRank = Int.max
            for index in 0..<(pieces.count - 1) {
                var pair = pieces[index]
                pair.append(contentsOf: pieces[index + 1])
                if let rank = ranks[pair], rank < bestRank {
                    bestIndex = index
                    bestRank = rank
                }
            }
            guard let index = bestIndex else { break }
            pieces[index].append(contentsOf: pieces[index + 1])
            pieces.remove(at: index + 1)
        }
        return pieces.count
    }
}
