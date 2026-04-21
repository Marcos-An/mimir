// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Mimir",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MimirCore",
            targets: ["MimirCore"]
        ),
        .executable(
            name: "MimirApp",
            targets: ["MimirApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.1.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "MimirCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .executableTarget(
            name: "MimirApp",
            dependencies: [
                "MimirCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "mimirTests",
            dependencies: ["MimirCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
