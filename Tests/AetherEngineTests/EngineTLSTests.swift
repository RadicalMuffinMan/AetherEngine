import Foundation
import Testing

@testable import AetherEngine

// Self-signed and private-CA media servers fail URLSession's system trust,
// which the FFmpeg stack never enforced, so hosts need an explicit opt-in.
// The resolver must stay on default handling for everything except an
// opted-in server-trust challenge.
@Suite("EngineTLS trust resolution", .serialized)
struct EngineTLSTests {

    private final class RecordingSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: "server.example", port: 443, protocol: "https",
            realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: RecordingSender())
    }

    private func disposition(
        allow: Bool, method: String
    ) -> URLSession.AuthChallengeDisposition {
        let previous = EngineTLS.allowUntrustedCertificates
        defer { EngineTLS.allowUntrustedCertificates = previous }
        EngineTLS.allowUntrustedCertificates = allow

        var got: URLSession.AuthChallengeDisposition?
        EngineTLS.resolve(challenge(method: method)) { disposition, _ in
            got = disposition
        }
        return got ?? .performDefaultHandling
    }

    @Test("Flag off keeps default handling for server trust")
    func flagOffServerTrust() {
        #expect(
            disposition(allow: false, method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }

    @Test("Non-trust challenges keep default handling even when opted in")
    func httpAuthUntouched() {
        #expect(
            disposition(allow: true, method: NSURLAuthenticationMethodHTTPBasic)
                == .performDefaultHandling)
    }

    @Test("Opted-in server trust without an evaluable trust object stays on default handling")
    func optedInWithoutTrustObject() {
        // A challenge built outside a live handshake carries no SecTrust, so
        // the resolver must fall through rather than send a nil credential.
        #expect(
            disposition(allow: true, method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }
}
