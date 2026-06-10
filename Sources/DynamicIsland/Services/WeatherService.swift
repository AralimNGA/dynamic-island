import Foundation
import Combine

/// Current weather via free, key-less APIs: IP geolocation (ipapi.co) + Open-Meteo.
final class WeatherService: ObservableObject {
    struct Weather: Equatable {
        let temp: Int
        let code: Int
        let city: String
        let wind: Int
    }

    @Published var weather: Weather?
    @Published var loading = false
    @Published var error: String?

    private var lastFetch: Date?

    func refreshIfStale() {
        // Cache for 10 minutes.
        if let last = lastFetch, Date().timeIntervalSince(last) < 600, weather != nil { return }
        refresh()
    }

    func refresh() {
        loading = true
        error = nil
        geolocate { [weak self] lat, lon, city in
            guard let self else { return }
            guard let lat, let lon else {
                DispatchQueue.main.async { self.loading = false; self.error = "Standort nicht gefunden" }
                return
            }
            self.fetchWeather(lat: lat, lon: lon, city: city ?? "")
        }
    }

    private func geolocate(_ done: @escaping (Double?, Double?, String?) -> Void) {
        guard let url = URL(string: "https://ipapi.co/json/") else { done(nil, nil, nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                done(nil, nil, nil); return
            }
            done(j["latitude"] as? Double, j["longitude"] as? Double, j["city"] as? String)
        }.resume()
    }

    private func fetchWeather(lat: Double, lon: Double, city: String) {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,wind_speed_10m"
        guard let url = URL(string: urlStr) else {
            DispatchQueue.main.async { self.loading = false; self.error = "Ungültige URL" }
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self else { return }
            DispatchQueue.main.async { self.loading = false }
            guard let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = j["current"] as? [String: Any] else {
                DispatchQueue.main.async { self.error = "Wetter nicht abrufbar" }
                return
            }
            let temp = (current["temperature_2m"] as? Double) ?? 0
            let code = (current["weather_code"] as? Int) ?? 0
            let wind = (current["wind_speed_10m"] as? Double) ?? 0
            DispatchQueue.main.async {
                self.weather = Weather(temp: Int(temp.rounded()), code: code,
                                       city: city, wind: Int(wind.rounded()))
                self.lastFetch = Date()
            }
        }.resume()
    }

    // MARK: WMO weather code → symbol + text

    static func symbol(for code: Int) -> String {
        switch code {
        case 0:        return "sun.max.fill"
        case 1, 2:     return "cloud.sun.fill"
        case 3:        return "cloud.fill"
        case 45, 48:   return "cloud.fog.fill"
        case 51...57:  return "cloud.drizzle.fill"
        case 61...67:  return "cloud.rain.fill"
        case 71...77:  return "cloud.snow.fill"
        case 80...82:  return "cloud.heavyrain.fill"
        case 85, 86:   return "cloud.snow.fill"
        case 95...99:  return "cloud.bolt.rain.fill"
        default:       return "cloud.fill"
        }
    }

    static func text(for code: Int) -> String {
        switch code {
        case 0:        return "Klar"
        case 1, 2:     return "Teils bewölkt"
        case 3:        return "Bewölkt"
        case 45, 48:   return "Nebel"
        case 51...57:  return "Nieselregen"
        case 61...67:  return "Regen"
        case 71...77:  return "Schnee"
        case 80...82:  return "Regenschauer"
        case 85, 86:   return "Schneeschauer"
        case 95...99:  return "Gewitter"
        default:       return "Wechselhaft"
        }
    }
}
