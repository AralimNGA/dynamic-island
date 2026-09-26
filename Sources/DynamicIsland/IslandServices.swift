import Foundation

/// Alle Modelle und Dienste der App an einem Ort, statt 15 Parameter durch jede
/// View zu reichen. Views beobachten nur die Teile, die sie wirklich brauchen.
final class IslandServices {
    let state: IslandState
    let media = MediaController()
    let battery = BatteryMonitor()
    let timer = TimerModel()
    let shelf = ShelfModel()
    let calendar = CalendarService()
    let claude = ClaudeService()
    let camera = CameraController()
    let recorder = AudioRecorder()
    let todo = TodoModel()
    let weather = WeatherService()
    let stocks = StockService()
    let deviceBattery = DeviceBatteryService()
    /// Akku von iPhone, iPad, Watch und AirPods am iPhone.
    lazy var remoteBattery = RemoteBatteryService(deviceBattery: deviceBattery)

    // System-Ereignisse
    let audio = AudioMonitor()
    let privacy = PrivacyMonitor()
    let lock = LockMonitor()
    let keys = KeyInterceptor()

    init(metrics: NotchMetrics) {
        state = IslandState(metrics: metrics)
    }
}
