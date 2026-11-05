import Foundation

/// The single shared model. SwiftUI views read its observable properties directly.
@MainActor
enum AppEnv {
    static let listen = ListenModel()
}
