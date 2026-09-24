import AppKit
import QuartzCore

/// Calls back once per refresh of the main display, so the pointer moves on every
/// frame the screen shows. A fixed 60 Hz timer on a 100 Hz display moved it on only
/// some frames, and the movement looked choppy. Without a display, or when asked, it
/// runs on a timer instead.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private let tick: () -> Void

    init(fromDisplay: Bool = true, timerInterval: Double = 1.0 / 120, _ tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if fromDisplay, let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: timerInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc private func frame(_ link: CADisplayLink) { tick() }

    func stop() {
        link?.invalidate()
        timer?.invalidate()
        link = nil
        timer = nil
    }
}
