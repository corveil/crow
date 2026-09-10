import Foundation
import Testing
@testable import CrowIPC

@Suite("HTTPJSONRPCClient URL resolution")
struct HTTPJSONRPCClientTests {
    @Test func defaultURLIsLoopback8787() {
        let url = HTTPJSONRPCClient.defaultURL(environment: [:])
        #expect(url.absoluteString == "http://127.0.0.1:8787/rpc")
    }

    @Test func CROW_HTTP_PORTOverridesPort() {
        let url = HTTPJSONRPCClient.defaultURL(environment: ["CROW_HTTP_PORT": "9191"])
        #expect(url.absoluteString == "http://127.0.0.1:9191/rpc")
    }

    @Test func CROW_HTTP_URLWinsAndFillsRpcPath() {
        let bare = HTTPJSONRPCClient.defaultURL(environment: [
            "CROW_HTTP_URL": "http://127.0.0.1:9000",
            "CROW_HTTP_PORT": "1",
        ])
        #expect(bare.absoluteString == "http://127.0.0.1:9000/rpc")

        let withPath = HTTPJSONRPCClient.defaultURL(environment: [
            "CROW_HTTP_URL": "http://127.0.0.1:9000/rpc",
        ])
        #expect(withPath.absoluteString == "http://127.0.0.1:9000/rpc")
    }

    @Test func shouldFallbackWhenNoSocketOverride() {
        #expect(HTTPJSONRPCClient.shouldFallback(environment: [:]) == true)
    }

    @Test func shouldNotFallbackWhenCROW_SOCKETIsSet() {
        #expect(HTTPJSONRPCClient.shouldFallback(environment: [
            "CROW_SOCKET": "/tmp/crow-test.sock",
        ]) == false)
    }

    @Test func explicitHTTPEnvForcesFallbackEvenWithCROW_SOCKET() {
        #expect(HTTPJSONRPCClient.shouldFallback(environment: [
            "CROW_SOCKET": "/tmp/crow-test.sock",
            "CROW_HTTP_PORT": "8787",
        ]) == true)
        #expect(HTTPJSONRPCClient.shouldFallback(environment: [
            "CROW_SOCKET": "/tmp/crow-test.sock",
            "CROW_HTTP_URL": "http://127.0.0.1:8787/rpc",
        ]) == true)
    }
}

@Suite("SocketError connect failure")
struct SocketErrorConnectFailureTests {
    @Test func connectAndCreateAreConnectFailures() {
        #expect(SocketError.connectionFailed(61).isConnectFailure)
        #expect(SocketError.createFailed(1).isConnectFailure)
        #expect(SocketError.timeout.isConnectFailure == false)
        #expect(SocketError.responseTooLarge.isConnectFailure == false)
        #expect(SocketError.writeFailed(1).isConnectFailure == false)
    }
}
