// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Mail",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Mail",
            targets: ["Mail"]
        ),
        .library(
            name: "MailConnection",
            targets: ["MailConnection"]
        ),
        .library(
            name: "SMTP",
            targets: ["SMTP"]
        ),
        .library(
            name: "IMAP",
            targets: ["IMAP"]
        ),
        .library(
            name: "MailFrame",
            targets: ["MailFrame"]
        ),
        .executable(
            name: "email",
            targets: ["email"]
        ),
        .executable(
            name: "t_mail",
            targets: ["MailTests"]
        ),
        .executable(
            name: "t_mail_live",
            targets: ["MailLiveTests"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Primitives.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Readers.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Parsing.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Milieu.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Frame.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/IO.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Arguments.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Testing.git", branch: "master"),
    ],
    targets: [
        // message model, MIME rendering and parsing; no networking
        .target(
            name: "Mail",
            dependencies: [
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Readers", package: "Readers"),
                .product(name: "Parsing", package: "Parsing"),
            ]
        ),

        // TLS transport, server configuration and SASL shared by SMTP and IMAP
        .target(
            name: "MailConnection",
            dependencies: [
                "Mail",
                .product(name: "Milieu", package: "Milieu"),
            ]
        ),

        .target(
            name: "SMTP",
            dependencies: [
                "Mail",
                "MailConnection",
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Parsing", package: "Parsing"),
            ]
        ),

        .target(
            name: "IMAP",
            dependencies: [
                "Mail",
                "MailConnection",
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Parsing", package: "Parsing"),
            ]
        ),

        // the `Mail` Frame module: accounts, identities and secrets declared in mail.frame
        .target(
            name: "MailFrame",
            dependencies: [
                "Mail",
                "MailConnection",
                "SMTP",
                "IMAP",
                .product(name: "Frame", package: "Frame"),
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Readers", package: "Readers"),
                .product(name: "IO", package: "IO"),
                .product(name: "Path", package: "Path"),
            ]
        ),

        // the `email` command line
        .executableTarget(
            name: "email",
            dependencies: [
                "Mail",
                "MailConnection",
                "SMTP",
                "IMAP",
                "MailFrame",
                .product(name: "Frame", package: "Frame"),
                .product(name: "Arguments", package: "Arguments"),
                .product(name: "Readers", package: "Readers"),
            ],
            path: "Sources/MailCLI"
        ),

        .executableTarget(
            name: "MailTests",
            dependencies: [
                "Mail",
                "MailConnection",
                "SMTP",
                "IMAP",
                "MailFrame",
                .product(name: "Milieu", package: "Milieu"),
                .product(name: "Testing", package: "Testing"),
            ],
            path: "Testing/MailTests"
        ),

        // probes real servers without credentials; needs network
        .executableTarget(
            name: "MailLiveTests",
            dependencies: [
                "MailConnection",
                "SMTP",
                "IMAP",
                .product(name: "Testing", package: "Testing"),
            ],
            path: "Testing/MailLiveTests"
        ),
    ]
)
