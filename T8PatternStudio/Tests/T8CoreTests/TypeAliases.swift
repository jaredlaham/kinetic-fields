@testable import T8Core

/// On macOS, XCTest pulls in ApplicationServices, whose QuickDraw headers
/// declare a C `struct Pattern`. Shadow it with T8Core's type in this module.
typealias Pattern = T8Core.Pattern
