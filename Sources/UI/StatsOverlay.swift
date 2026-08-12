import AppKit
import Foundation

/// A floating panel overlay that displays multi-component transport stats at 1 Hz.
/// One instance per window (Sender or Receiver). The overlay reads stats via the
/// provided closure each tick, rendering "—" for any nil component.
@MainActor
final class StatsOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private weak var parentWindow: NSWindow?
    private let title: String
    private let provider: () -> (transport: LinkMode, stats: TransportStats?)

    init(title: String,
         parent: NSWindow,
         provider: @escaping () -> (transport: LinkMode, stats: TransportStats?)) {
        self.title = title
        self.parentWindow = parent
        self.provider = provider

        let frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBordered = false
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: frame)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        panel.contentView = container
    }

    deinit {
        timer?.invalidate()
    }

    func show() {
        guard let parent = parentWindow else { return }
        repositionPanel(in: parent)
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        parentWindow?.removeChildWindow(panel)
    }

    var isVisible: Bool { panel.isVisible }

    private func repositionPanel(in parent: NSWindow) {
        let parentFrame = parent.frame
        let margin: CGFloat = 12
        let x = parentFrame.maxX - panel.frame.width - margin
        let y = parentFrame.maxY - panel.frame.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func tick() {
        if let parent = parentWindow {
            repositionPanel(in: parent)
        }
        let (transport, statsOpt) = provider()
        var lines: [String] = []
        lines.append(pad("Window:", title))
        lines.append(pad("Transport:", transport.rawValue))
        guard let s = statsOpt else {
            lines.append("(no stats)")
            label.stringValue = lines.joined(separator: "\n")
            return
        }
        lines.append(pad("Bitrate:", String(format: "%.1f Mbps", s.bitrateKbps / 1000.0)))
        lines.append("")
        lines.append("Latency")
        lines.append(pad("  Send:", fmt(s.sendLatencyMs)))
        lines.append(pad("  Wire:", fmt(s.wireLatencyMs)))
        lines.append(pad("  Receive:", fmt(s.receiveLatencyMs)))
        lines.append(pad("  ────────", ""))
        lines.append(pad("  End-to-end:", fmt(s.endToEndLatencyMs)))
        if s.jitterBufferMs != nil {
            lines.append(pad("  Jitter buf:", fmt(s.jitterBufferMs)))
        }
        lines.append("")
        lines.append(pad("Dropped:", "\(s.framesDropped)"))
        lines.append(pad("CPU:", String(format: "%.0f%%", s.cpuPercent)))
        label.stringValue = lines.joined(separator: "\n")
    }

    private func pad(_ key: String, _ value: String) -> String {
        let keyWidth = 14
        let padding = max(0, keyWidth - key.count)
        return key + String(repeating: " ", count: padding) + value
    }

    private func fmt(_ ms: Double?) -> String {
        guard let ms = ms else { return "—" }
        return String(format: "%.0f ms", ms)
    }
}
