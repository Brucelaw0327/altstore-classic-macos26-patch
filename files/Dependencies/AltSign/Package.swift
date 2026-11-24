// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let package = Package(
    name: "AltSign",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
    ],
    products: [
        // PATCHED: built as static. As a .dynamic product Xcode emits a codeless
        // AltSign-Dynamic.framework (one framework per target, no product binary),
        // which the AltJIT/AltServer link steps then fail to open.
        .library(
            name: "AltSign-Dynamic",
            targets: ["AltSign", "CAltSign", "AltCrypto", "CAltCrypto", "ldid", "ldid-core", "OpenSSL"]
        ),
        .library(
            name: "AltSign-Static",
            targets: ["AltSign", "CAltSign", "AltCrypto", "CAltCrypto", "ldid", "ldid-core"]
        ),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "OpenSSL",
            path: "Dependencies/OpenSSL/Frameworks/OpenSSL.xcframework"
        ),
        
        .target(
            name: "ldid-core",
            path: "Dependencies/ldid",
            exclude: [
                "ldid.hpp",
                "ldid.cpp",
                "version.sh",
                "COPYING",
                "control.sh",
                "control",
                "ios.sh",
                "make.sh",
                "deb.sh",
                "plist.sh",
                "libplist/include",
                "libplist/include/Makefile.am",
                "libplist/fuzz",
                "libplist/cython",
                "libplist/m4",
                "libplist/test",
                "libplist/tools",
                "libplist/AUTHORS",
                "libplist/autogen.sh",
                "libplist/configure.ac",
                "libplist/COPYING",
                "libplist/COPYING.LESSER",
                "libplist/doxygen.cfg.in",
                "libplist/Makefile.am",
                "libplist/NEWS",
                "libplist/README.md",
                "libplist/src/Makefile.am",
                "libplist/src/libplist++.pc.in",
                "libplist/src/libplist.pc.in",
                "libplist/libcnary/cnary.c",
                "libplist/libcnary/COPYING",
                "libplist/libcnary/Makefile.am",
                "libplist/libcnary/README",
            ],
            sources: [
                "lookup2.c",
                "libplist/src",
                "libplist/libcnary",
            ],
            publicHeadersPath: "",
            cSettings: [
                .headerSearchPath("libplist/include"),
                .headerSearchPath("libplist/src"),
                .headerSearchPath("libplist/libcnary/include"),
                .headerSearchPath("../OpenSSL/ios/include"),
                
                .unsafeFlags(["-w"])
            ],
            cxxSettings: [
                .unsafeFlags(["-w"])
            ]
        ),
        .target(
            name: "ldid",
            dependencies: ["ldid-core"],
            path: "AltSign/ldid",
            exclude: [
                "alt_ldid.hpp",
            ],
            sources: [
                "alt_ldid.cpp",
            ],
            publicHeadersPath: "",
            cSettings: [
                .headerSearchPath("../../Dependencies/ldid"),
                .headerSearchPath("../../Dependencies/ldid/libplist/include"),
                .headerSearchPath("../../Dependencies/ldid/libplist/src"),
                .headerSearchPath("../../Dependencies/ldid/libplist/libcnary/include"),
                .headerSearchPath("../../Dependencies/OpenSSL/ios/include"),
            ],
            cxxSettings: [
                .unsafeFlags(["-w"])
            ],
            // PATCHED: when targets are built as standalone dynamic frameworks,
            // each one must link OpenSSL itself instead of inheriting it from the product.
            linkerSettings: [
                .linkedFramework("OpenSSL")
            ]
        ),
        
        .target(
            name: "CAltCrypto",
            path: "Dependencies/altcrypto",
            exclude: [
                "Sources/CoreCryptoMacros.swift"
            ],
            cSettings: [
                .headerSearchPath("include/corecrypto"),
                .define("CORECRYPTO_DONOT_USE_TRANSPARENT_UNION=1")
            ]
        ),
        .target(
            name: "AltCrypto",
            dependencies: ["CAltCrypto"],
            path: "Dependencies/altcrypto/Sources",
            exclude: [
                "ccsrp.m"
            ],
            sources: [
                "CoreCryptoMacros.swift"
            ],
            cSettings: [
                .define("CORECRYPTO_DONOT_USE_TRANSPARENT_UNION=1")
            ]
        ),

        .target(
            name: "CAltSign",
            dependencies: ["AltCrypto", "ldid"],
            path: "",
            exclude: [
                "AltSign/ldid/alt_ldid.cpp",
                "AltSign/ldid/alt_ldid.hpp",
                "AltSign/Sources",
                "AltSign/include/module.modulemap",
                "Dependencies/altcrypto",
                "Dependencies/corecrypto",
                "Dependencies/ldid",
                "Dependencies/OpenSSL",
                "Dependencies/minizip/iowin32.c",
                "Dependencies/minizip/Makefile",
                "Dependencies/minizip/minizip.c",
                "Dependencies/minizip/miniunz.c",
            ],
            publicHeadersPath: "AltSign/include",
            cSettings: [
                // Recursive wildcard paths no longer work as of Xcode 16 :(
                // .headerSearchPath("AltSign/**"),
                .headerSearchPath("AltSign/include/AltSign"),
                .headerSearchPath("Dependencies/minizip"),
                .headerSearchPath("Dependencies/OpenSSL/ios/include"),
                .headerSearchPath("Dependencies/ldid/libplist/include"),
                .headerSearchPath("Dependencies/ldid"),
                .define("unix=1"),
            ],
            linkerSettings: [
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("Security"),
                // PATCHED: CAltSign calls OpenSSL directly and is linked as its own framework.
                .linkedFramework("OpenSSL"),
            ]
        ),
        .target(
            name: "AltSign",
            dependencies: ["CAltSign"],
            path: "AltSign/Sources",
            cSettings: [
                .headerSearchPath("Dependencies/minizip"),
                .define("CORECRYPTO_DONOT_USE_TRANSPARENT_UNION=1"),
            ],
            // PATCHED: alt_cc* symbols live in libcorecrypto_static.a, which is built by
            // corecrypto.xcodeproj (not a SwiftPM target), so link it explicitly here.
            linkerSettings: [
                .unsafeFlags(["-L/tmp/altstore-build/Build/Products/Release"]),
                .linkedLibrary("corecrypto_static"),
            ]
        )
    ],
    
    cLanguageStandard: CLanguageStandard.gnu11,
    cxxLanguageStandard: .cxx14
)
