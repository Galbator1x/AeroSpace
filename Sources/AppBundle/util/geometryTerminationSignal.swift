import Foundation

// Dispatch invokes the handler on the main queue, outside POSIX signal-handler context.
@MainActor
func makeGeometryTerminationSignal(_ handler: @escaping @MainActor @Sendable () -> Void) -> DispatchSourceSignal {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { handler() } }
    source.activate()
    return source
}
