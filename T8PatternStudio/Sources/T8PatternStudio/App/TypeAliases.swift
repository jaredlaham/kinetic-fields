import T8Core

/// AppKit re-exports QuickDraw's legacy C `struct Pattern`. Declaring the alias
/// in this module makes every unqualified `Pattern` in the app mean T8Core's.
typealias Pattern = T8Core.Pattern
