// swift-tools-version: 6.0
//
// MoolahubKit: every line of app code lives in this package. The Xcode app
// target (apps/ios/Moolahub) is a thin shell that links `AppFeature`.
//
// Ownership (see apps/ios/README.md):
//   Shared (architect / integration only): Domain, DesignSystem, APIClient,
//   Persistence, Auth, AppFeature, this file.
//   Feature engineers: only the files inside their own Sources/Feature* folder.
import PackageDescription

/// Applied to every target. Swift 6 language mode (complete strict
/// concurrency) is the default for tools-version 6.0; `DEBUG` is defined
/// explicitly so `#if DEBUG` code (developer settings) can never compile into
/// a Release build, whichever tool builds the package.
let commonSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug)),
]

/// Dependencies every feature target gets. Features never depend on each other
/// or on AppFeature; cross-feature navigation goes through `Navigator` (Auth).
let featureDependencies: [Target.Dependency] = [
    "Domain", "DesignSystem", "APIClient", "Persistence", "Auth",
]

let package = Package(
    name: "MoolahubKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "APIClient", targets: ["APIClient"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Auth", targets: ["Auth"]),
        .library(name: "AppFeature", targets: ["AppFeature"]),
        .library(name: "FeatureAuth", targets: ["FeatureAuth"]),
        .library(name: "FeatureHome", targets: ["FeatureHome"]),
        .library(name: "FeatureSavings", targets: ["FeatureSavings"]),
        .library(name: "FeatureCircles", targets: ["FeatureCircles"]),
        .library(name: "FeatureActivity", targets: ["FeatureActivity"]),
        .library(name: "FeatureAccount", targets: ["FeatureAccount"]),
        .library(name: "FeatureStreaks", targets: ["FeatureStreaks"]),
        .library(name: "FeatureLearn", targets: ["FeatureLearn"]),
    ],
    targets: [
        // MARK: Shared core
        .target(name: "Domain", swiftSettings: commonSettings),
        .target(name: "Persistence", swiftSettings: commonSettings),
        .target(name: "APIClient", dependencies: ["Domain"], swiftSettings: commonSettings),
        .target(
            name: "DesignSystem",
            dependencies: ["Domain"],
            resources: [.process("Resources")],
            swiftSettings: commonSettings
        ),
        .target(
            name: "Auth",
            dependencies: ["Domain", "APIClient", "Persistence"],
            swiftSettings: commonSettings
        ),

        // MARK: Features (one engineer each; README.md in each folder)
        .target(name: "FeatureAuth", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureHome", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureSavings", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureCircles", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureActivity", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureAccount", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureStreaks", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),
        .target(name: "FeatureLearn", dependencies: featureDependencies, exclude: ["README.md"], swiftSettings: commonSettings),

        // MARK: Composition root
        .target(
            name: "AppFeature",
            dependencies: featureDependencies + [
                "FeatureAuth", "FeatureHome", "FeatureSavings",
                "FeatureCircles", "FeatureActivity", "FeatureAccount",
                "FeatureStreaks", "FeatureLearn",
            ],
            swiftSettings: commonSettings
        ),

        // MARK: Tests (Swift Testing)
        .testTarget(name: "DomainTests", dependencies: ["Domain"], resources: [.copy("Fixtures")], swiftSettings: commonSettings),
        .testTarget(name: "APIClientTests", dependencies: ["APIClient", "Domain"], swiftSettings: commonSettings),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], swiftSettings: commonSettings),
        .testTarget(name: "AuthTests", dependencies: ["Auth", "APIClient", "Domain", "Persistence"], swiftSettings: commonSettings),
    ]
)
