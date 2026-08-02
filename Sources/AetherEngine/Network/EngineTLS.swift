import Foundation

/// Host-app TLS trust policy for the engine's outbound HTTP connections.
///
/// URLSession enforces system certificate trust, which the in-demuxer network
/// stacks this engine replaces never did. A media server fronted by a
/// self-signed or private-CA certificate therefore keeps working in a host
/// whose own API layer bypasses trust, while every engine fetch fails its
/// handshake before a byte is read and the open surfaces as bare invalid
/// data. The host opts in explicitly; while the flag is off every challenge
/// keeps the system's default handling.
public enum EngineTLS {

    /// Accept server certificates that fail system trust evaluation.
    /// Read per challenge, so flipping it applies from the next connection
    /// without rebuilding sessions. Lock-guarded like `EngineLog.handler`.
    public static var allowUntrustedCertificates: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowUntrusted }
        set { lock.lock(); _allowUntrusted = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _allowUntrusted = false

    /// Session-level delegate for the owned sessions that otherwise run
    /// without one (disc reader, HLS ingest readers, audio tap fetcher) and
    /// the fallback for tasks that missed a per-task delegate.
    static let sessionDelegate = SessionTrustDelegate()

    /// Single disposition shared by the session-level delegate and the
    /// per-task delegates in AVIOReader. Anything other than an opted-in
    /// server-trust challenge is left to default handling, so client
    /// certificates and HTTP auth behave exactly as before.
    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            allowUntrustedCertificates,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    final class SessionTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?)
                -> Void
        ) {
            EngineTLS.resolve(challenge, completionHandler: completionHandler)
        }
    }
}
