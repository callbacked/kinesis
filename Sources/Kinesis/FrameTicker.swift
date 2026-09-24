import AppKit
import QuartzCore

/// Calls back once per refresh of the display under the pointer, at that display's
/// highest rate, so the pointer moves on every frame the screen shows. A fixed 60 Hz
/// timer on a 100 Hz display moved it on only some frames, which looked choppy.
/// Refresh rates differ between displays and can change, so the ticker follows the
/// pointer from one display to the next.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private weak var screen: NSScreen?
    private var timer: Timer?
    private var frames = 0
    private let tick: () -> Void

    /// With an interval, it runs on a timer instead of a display.
    init(timerInterval: Double? = nil, _ tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if timerInterval == nil, let screen = Self.screenUnderPointer() {
            follow(screen)
        } else {
            let timer = Timer(timeInterval: timerInterval ?? 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    private func follow(_ screen: NSScreen) {
        link?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(frame))
        let fastest = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest / 2, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
        self.screen = screen
    }

    @objc private func frame(_ link: CADisplayLink) {
        tick()
        frames += 1
        // A few times a second, move to the display the pointer is on.
        guard frames % 30 == 0, let under = Self.screenUnderPointer(), under != screen else { return }
        follow(under)
    }

    func stop() {
        link?.invalidate()
        timer?.invalidate()
        link = nil
        timer = nil
    }
}
