// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Still", targets: ["Still"])],
    targets: [
        .target(name: "MixerCore"),
        .target(name: "AudioDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "Still", dependencies: ["MixerCore", "AudioDSP"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("CoreAudio"), .linkedFramework("ServiceManagement")
        ]),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore", "AudioDSP"])
    ],
    cxxLanguageStandard: .cxx17
)
