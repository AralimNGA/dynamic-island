import Foundation

final class HotspotDelegate: NSObject {
    @objc(session:updatedFoundDevices:)
    func session(_ session: AnyObject, updatedFoundDevices devices: NSArray) {
        print("delegate: \(devices.count) devices, main=\(Thread.isMainThread)")
        for case let d as NSObject in devices {
            let model = d.value(forKey: "model") as? String ?? "?"
            let batt = (d.value(forKey: "batteryLife") as? NSNumber)?.intValue ?? -1
            let bars = (d.value(forKey: "signalStrength") as? NSNumber)?.intValue ?? -1
            print("  \(model) battery~\(batt)% bars=\(bars)")
        }
    }
}

guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
      let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { fatalError("Sharing not available") }
let delegate = HotspotDelegate()
let session = cls.init()
session.setValue(delegate, forKey: "delegate")
session.perform(NSSelectorFromString("startBrowsing"))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 8))
session.perform(NSSelectorFromString("stopBrowsing"))
