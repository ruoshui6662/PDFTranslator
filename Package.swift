// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFTranslator",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PDFTranslateKit", targets: ["PDFTranslateKit"]),
        .library(name: "TranslationEngines", targets: ["TranslationEngines"]),
        .executable(name: "pdftranslate-cli", targets: ["pdftranslate-cli"]),
        .executable(name: "PDFTranslatorApp", targets: ["PDFTranslatorApp"])
    ],
    targets: [
        .target(
            name: "CPDFium",
            path: "Packages/CPDFium",
            sources: ["src/cpdfium_loader.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "TranslationEngines",
            path: "Packages/TranslationEngines",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PDFTranslateKit",
            dependencies: [
                "CPDFium",
                "TranslationEngines"
            ],
            path: "Packages/PDFTranslateKit"
        ),
        .executableTarget(
            name: "pdftranslate-cli",
            dependencies: [
                "PDFTranslateKit",
                "TranslationEngines"
            ],
            path: "Tools/pdftranslate-cli"
        ),
        .executableTarget(
            name: "PDFTranslatorApp",
            dependencies: [
                "PDFTranslateKit",
                "TranslationEngines"
            ],
            path: "App",
            exclude: ["Info.plist", "PDFTranslator.entitlements", "Resources/Localizable.xcstrings"]
        ),
        .testTarget(
            name: "PDFTranslateKitTests",
            dependencies: [
                "PDFTranslateKit",
                "TranslationEngines"
            ],
            path: "Tests/PDFTranslateKitTests"
        )
    ]
)
