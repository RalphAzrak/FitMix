#if FM_BENCH
import QuartzCore
import UIKit

/// Profiling builds only: counts frames that missed their display deadline during each benchmark phase.
final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var phase = ""
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var missed = 0
    private var worst: CFTimeInterval = 0

    func start(_ name: String) {
        report()
        phase = name
        frames = 0; missed = 0; worst = 0; last = 0
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        report()
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let interval = link.timestamp - last
        let expected = link.targetTimestamp - link.timestamp
        frames += 1
        worst = max(worst, interval)
        if interval > max(expected, 1.0 / 120) * 1.5 { missed += Int((interval / max(expected, 1.0 / 120)).rounded()) - 1 }
    }

    private func report() {
        guard !phase.isEmpty else { return }
        print("FM_FRAMES \(phase): frames \(frames) missed \(missed) worst \(Int(worst * 1000)) ms")
    }
}
#endif
