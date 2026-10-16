import Foundation

/// Turns a swipe across the keyboard (the letters the finger passed over) into the most likely
/// word, using a list of the 40,000 most common English words with how often they're used.
final class SwipeDecoder {
    static let shared = SwipeDecoder()

    private struct Word { let text: [Character]; let freq: Double }
    /// Words grouped by first + last letter, so only a handful are checked per swipe
    private var index: [String: [Word]] = [:]
    private var loaded = false

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let f = Double(parts[1]) else { continue }
            let w = Array(String(parts[0]))
            guard w.count >= 2, let first = w.first, let last = w.last else { continue }
            index["\(first)\(last)", default: []].append(Word(text: w, freq: f))
        }
    }

    /// Best guesses, most likely first. `path` is the letters passed over, in order.
    func decode(_ path: [Character]) -> [String] {
        load()
        guard path.count >= 2, let first = path.first, let last = path.last else { return [] }
        var scored: [(String, Double)] = []
        // The start and end of a swipe are the most reliable; allow the neighbours of the last key too
        for word in index["\(first)\(last)"] ?? [] where fits(word.text, path) {
            // Common words win; longer words that use more of the swipe get a small boost
            let coverage = Double(word.text.count) / Double(max(path.count, 1))
            let score = word.freq + 1.2 * min(coverage, 1) + 0.15 * Double(word.text.count)
            scored.append((String(word.text), score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(4).map { $0.0 }
    }

    /// Every letter of the word appears along the swipe, in order (a doubled letter like the
    /// "ll" in "hello" may come from a single key)
    private func fits(_ word: [Character], _ path: [Character]) -> Bool {
        var i = 0
        for ch in word {
            if i > 0, path[i - 1] == ch { continue }   // same key again
            while i < path.count, path[i] != ch { i += 1 }
            if i == path.count { return false }
            i += 1
        }
        return true
    }
}
