// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StageGlassLink",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "StageGlassLinkCore", targets: ["StageGlassLinkCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.16.0")
    ],
    targets: [
        .target(
            name: "StageGlassLinkCore",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "Sources",
            exclude: [
                "App", "Audio", "Capture", "Model", "NDI", "QuicLink", "Receive", "Recording", "UI",
                "Session/NDIMediaSession.swift",
                "Transport/NDITransport.swift", "Transport/VideoTransport.swift", "Transport/WarpStreamTransport.swift"
            ],
            sources: [
                "Session/AudioSampleBufferFactory.swift",
                "Session/LinkReceiverSession.swift",
                "Session/LiveKitMediaSession.swift",
                "Session/LocalMediaSource.swift",
                "Session/MediaSession.swift",
                "LiveKitAdapter/LiveKitSDKClient.swift",
                "Transport/TransportStats.swift"
            ]
        ),
        .testTarget(
            name: "StageGlassLinkCoreTests",
            dependencies: ["StageGlassLinkCore"],
            path: "MobileTests"
        )
    ]
)
