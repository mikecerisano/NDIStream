import Foundation

/// Multi-component transport statistics for the NDI/QuicLink/WarpStream shootout.
///
/// Latency fields are milliseconds. `nil` means the transport can't measure that
/// component (e.g., NDI exposes only `endToEndLatencyMs`). `jitterBufferMs` is the
/// current jitter-buffer depth — a setting, not a latency — included separately so
/// it isn't summed by mistake.
public struct TransportStats: Equatable {
    public let bitrateKbps: Double
    public let sendLatencyMs: Double?
    public let wireLatencyMs: Double?
    public let receiveLatencyMs: Double?
    public let endToEndLatencyMs: Double?
    public let jitterBufferMs: Double?
    public let framesDropped: UInt64
    public let cpuPercent: Double

    public init(bitrateKbps: Double,
         sendLatencyMs: Double? = nil,
         wireLatencyMs: Double? = nil,
         receiveLatencyMs: Double? = nil,
         endToEndLatencyMs: Double? = nil,
         jitterBufferMs: Double? = nil,
         framesDropped: UInt64,
         cpuPercent: Double) {
        self.bitrateKbps = bitrateKbps
        self.sendLatencyMs = sendLatencyMs
        self.wireLatencyMs = wireLatencyMs
        self.receiveLatencyMs = receiveLatencyMs
        self.endToEndLatencyMs = endToEndLatencyMs
        self.jitterBufferMs = jitterBufferMs
        self.framesDropped = framesDropped
        self.cpuPercent = cpuPercent
    }
}
