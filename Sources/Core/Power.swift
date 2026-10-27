import Observation
import Foundation

/// Low Power Mode and memory pressure, so Lumen does less when the Mac asks it to.
@Observable
final class Power {
    static let shared = Power()
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var memory: DispatchSourceMemoryPressure?

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            if self?.lowPower != on { self?.lowPower = on }
            if on { WindowRegistry.shared.browsers.forEach { $0.hibernateIdle() } }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            Self.relieveMemory(critical: event.contains(.critical))
        }
        source.resume()
        memory = source
    }

    /// When macOS runs short of memory: background tabs idle for a couple of minutes sleep,
    /// and when it's critical every background tab sleeps and cached icons are dropped.
    static func relieveMemory(critical: Bool) {
        for b in WindowRegistry.shared.browsers { b.hibernate(idleFor: critical ? 0 : 120) }
        if critical { Favicons.shared.trimMemory() }
    }
}
