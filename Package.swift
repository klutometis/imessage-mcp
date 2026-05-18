// swift-tools-version: 6.0

// imessage-mcp: stdio MCP server for iMessage on macOS.
//
// Forked from ~/prg/imessage-gemini's MessageSender/DatabaseMonitor/MessageDecoder.
// Drops Vapor, SendBlue HTTP API, and Gemini integration; replaces with a focused
// stdio MCP server using the official Model Context Protocol Swift SDK.
//
// Targets:
//   iMessageCore   — library: send, read, decode (lifted from imessage-gemini)
//   iMessageMCP    — executable: stdio MCP server, 3 tools
//
// Build:  swift build --product imessage-mcp
// Run:    .build/debug/imessage-mcp  (speaks JSON-RPC on stdin/stdout)

import PackageDescription

let package = Package(
    name: "imessage-mcp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "iMessageCore", targets: ["iMessageCore"]),
        .executable(name: "imessage-mcp", targets: ["iMessageMCP"]),
    ],
    dependencies: [
        // SQLite wrapper
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        // Structured logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // TypedStream decoder for iMessage attributedBody (rich text, edits, replies)
        .package(url: "https://github.com/mattt/Madrid.git", from: "0.2.0"),
        // Official MCP Swift SDK
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "iMessageCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "TypedStream", package: "Madrid"),
            ],
            path: "Sources/iMessageCore"
        ),
        .executableTarget(
            name: "iMessageMCP",
            dependencies: [
                "iMessageCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/iMessageMCP"
        ),
    ]
)
