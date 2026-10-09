// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentLive",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .executable(name: "AgentLive", targets: ["MeetingMac"]),
        .library(name: "AgentServices", targets: ["AgentServices"]),
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingLive", targets: ["MeetingLive"]),
        .library(name: "AgentUI", targets: ["AgentUI"]),
        .executable(name: "MeetingChecks", targets: ["MeetingChecks"]),
        .executable(name: "AgentChecks", targets: ["AgentChecks"]),
        .executable(name: "AgentDriveChecks", targets: ["AgentDriveChecks"])
    ],
    targets: [
        .target(name: "MeetingCore"),
        .target(name: "MeetingLive", dependencies: ["MeetingCore"]),
        .target(name: "AgentServices", dependencies: ["MeetingCore", "MeetingLive"]),
        .target(name: "AgentUI", dependencies: ["AgentServices"]),
        .target(name: "MeetingServices", dependencies: ["MeetingCore", "MeetingLive", "AgentServices"]),
        .executableTarget(name: "MeetingMac", dependencies: ["MeetingCore", "MeetingServices", "MeetingLive", "AgentServices", "AgentUI"]),
        .executableTarget(name: "MeetingChecks", dependencies: ["MeetingCore", "MeetingServices", "MeetingLive", "AgentServices"], path: "Tests"),
        .executableTarget(name: "AgentChecks", dependencies: ["AgentServices", "MeetingLive", "MeetingCore"]),
        .executableTarget(name: "AgentDriveChecks", dependencies: ["AgentServices"])
    ],
    swiftLanguageModes: [.v5]
)
