import MLX

/// Even clearing MLX's cache can initialize its Metal device. Keep that call out of simulators.
enum MLXRuntimeSupport {
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    static func requireSupported() throws {
        guard isSupported else { throw LocalChatError.simulatorNotSupported }
    }

    static func clearCache() {
        #if !targetEnvironment(simulator)
        Memory.clearCache()
        #endif
    }
}
