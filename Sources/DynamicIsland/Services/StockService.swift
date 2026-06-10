import Foundation
import Combine

/// Stock quotes via Yahoo Finance's public chart endpoint (no API key).
final class StockService: ObservableObject {
    struct Quote: Identifiable, Equatable {
        var id: String { symbol }
        let symbol: String
        let name: String
        let price: Double
        let changePct: Double
        let currency: String
    }

    @Published var quotes: [Quote] = []
    @Published var loading = false
    @Published var error: String?

    private var lastFetch: Date?

    func refreshIfStale(symbols: [String]) {
        if let last = lastFetch, Date().timeIntervalSince(last) < 120, !quotes.isEmpty { return }
        refresh(symbols: symbols)
    }

    func refresh(symbols: [String]) {
        let syms = symbols.map { $0.uppercased() }.filter { !$0.isEmpty }
        guard !syms.isEmpty else { quotes = []; return }
        loading = true
        error = nil

        let group = DispatchGroup()
        var results: [String: Quote] = [:]
        let lock = NSLock()

        for symbol in syms {
            group.enter()
            let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)"
            guard let url = URL(string: urlStr) else { group.leave(); continue }
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")  // Yahoo blocks empty UA
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { group.leave() }
                guard let data,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let chart = j["chart"] as? [String: Any],
                      let resultArr = chart["result"] as? [[String: Any]],
                      let meta = resultArr.first?["meta"] as? [String: Any],
                      let price = meta["regularMarketPrice"] as? Double else { return }
                let prev = (meta["chartPreviousClose"] as? Double)
                    ?? (meta["previousClose"] as? Double) ?? price
                let changePct = prev > 0 ? (price - prev) / prev * 100 : 0
                let currency = (meta["currency"] as? String) ?? "USD"
                let name = (meta["shortName"] as? String)
                    ?? (meta["longName"] as? String) ?? symbol
                let q = Quote(symbol: symbol, name: name, price: price,
                              changePct: changePct, currency: currency)
                lock.lock(); results[symbol] = q; lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.loading = false
            let ordered = syms.compactMap { results[$0] }
            self.quotes = ordered
            if ordered.isEmpty { self.error = "Kurse nicht abrufbar" }
            self.lastFetch = Date()
        }
    }
}
