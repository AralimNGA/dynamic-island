import AppKit

// Private CoreGraphics-Server-API (SkyLight). Dasselbe Vorgehen nutzen
// boring.notch und Parrot: Ein eigener Space auf höchster absoluter Ebene
// gehört zu keinem Schreibtisch – Fenster darin gleiten beim Wechsel von
// Schreibtischen, bei Mission Control und bei Vollbild-Apps nicht mit.

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> UInt

@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: UInt, _ flag: Int, _ options: NSDictionary?) -> UInt64

@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: UInt, _ space: UInt64)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: UInt, _ space: UInt64, _ level: Int)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: UInt, _ windows: NSArray, _ spaces: NSArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: UInt, _ windows: NSArray, _ spaces: NSArray)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: UInt, _ spaces: NSArray)

@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: UInt, _ spaces: NSArray)

/// Ein eigener, fixer Space für die Island.
final class PrivateSpace {
    static let shared = PrivateSpace()

    private let connection = _CGSDefaultConnection()
    private let id: UInt64
    private var destroyed = false

    private init() {
        // Flag muss 1 sein, sonst zeichnet der Finder Schreibtisch-Symbole in den Space.
        id = CGSSpaceCreate(connection, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(connection, id, Int(Int32.max))
        CGSShowSpaces(connection, [NSNumber(value: id)])
    }

    /// Fenster muss bereits eine gültige `windowNumber` haben (nach orderFront).
    func add(_ window: NSWindow) {
        guard !destroyed, window.windowNumber > 0 else { return }
        CGSAddWindowsToSpaces(connection, [NSNumber(value: window.windowNumber)], [NSNumber(value: id)])
    }

    func remove(_ window: NSWindow) {
        guard !destroyed, window.windowNumber > 0 else { return }
        CGSRemoveWindowsFromSpaces(connection, [NSNumber(value: window.windowNumber)], [NSNumber(value: id)])
    }

    /// Beim Beenden aufräumen, sonst bleibt ein verwaister Space im WindowServer.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        CGSHideSpaces(connection, [NSNumber(value: id)])
        CGSSpaceDestroy(connection, id)
    }
}
