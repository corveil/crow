import Foundation
import Testing
@testable import CrowIPC

// MARK: - Test Helpers

private enum TestError: Error, LocalizedError {
    case generic(String)
    var errorDescription: String? {
        switch self { case .generic(let msg): msg }
    }
}

private enum CodedError: Error, LocalizedError, RPCErrorCoded {
    case badParams(String)
    var rpcErrorCode: Int { RPCErrorCode.invalidParams }
    var errorDescription: String? {
        switch self { case .badParams(let msg): msg }
    }
}

/// Actor to safely capture params from a @Sendable handler closure.
private actor ParamsBox {
    var value: [String: JSONValue]?
    func store(_ params: [String: JSONValue]) { value = params }
}

// MARK: - Routing

@Test func routesToCorrectHandler() async {
    let router = CommandRouter(handlers: [
        "echo": { @Sendable params in params },
        "other": { @Sendable _ in ["result": .string("other")] },
    ])

    let request = JSONRPCRequest(id: 1, method: "echo", params: ["key": .string("val")])
    let response = await router.handle(request: request)
    #expect(response.result?["key"] == .string("val"))
    #expect(response.error == nil)
}

@Test func unknownMethodReturnsError() async {
    let router = CommandRouter(handlers: [:])
    let request = JSONRPCRequest(id: 1, method: "nonexistent")
    let response = await router.handle(request: request)

    #expect(response.error?.code == RPCErrorCode.methodNotFound)
    #expect(response.error?.message.contains("nonexistent") == true)
    #expect(response.result == nil)
}

@Test func genericErrorReturnsApplicationError() async {
    let router = CommandRouter(handlers: [
        "fail": { @Sendable _ in throw TestError.generic("something broke") },
    ])

    let request = JSONRPCRequest(id: 1, method: "fail")
    let response = await router.handle(request: request)

    #expect(response.error?.code == RPCErrorCode.applicationError)
    #expect(response.error?.message == "something broke")
}

@Test func codedErrorReturnsSpecificCode() async {
    let router = CommandRouter(handlers: [
        "validate": { @Sendable _ in throw CodedError.badParams("missing field") },
    ])

    let request = JSONRPCRequest(id: 1, method: "validate")
    let response = await router.handle(request: request)

    #expect(response.error?.code == RPCErrorCode.invalidParams)
    #expect(response.error?.message == "missing field")
}

@Test func nilParamsCoalescedToEmptyDict() async {
    let box = ParamsBox()
    let router = CommandRouter(handlers: [
        "check": { @Sendable params in
            await box.store(params)
            return [:]
        },
    ])

    let request = JSONRPCRequest(id: 1, method: "check", params: nil)
    _ = await router.handle(request: request)
    let received = await box.value
    #expect(received == [:])
}

@Test func responsePreservesRequestID() async {
    let router = CommandRouter(handlers: [
        "ping": { @Sendable _ in ["pong": .bool(true)] },
    ])

    let request = JSONRPCRequest(id: 42, method: "ping")
    let response = await router.handle(request: request)
    #expect(response.id == 42)
}

// MARK: - Fallback delegation (CROW-581)

@Test func delegatesUnknownMethodToFallback() async {
    let engine = CommandRouter(handlers: [
        "hook-event": { @Sendable _ in ["handled_by": .string("engine")] },
    ])
    let daemon = CommandRouter(handlers: [
        "list-sessions": { @Sendable _ in ["handled_by": .string("daemon")] },
    ], fallback: engine)

    let resp = await daemon.handle(request: JSONRPCRequest(id: 1, method: "hook-event"))
    #expect(resp.error == nil)
    #expect(resp.result?["handled_by"] == .string("engine"))
}

@Test func primaryHandlerShadowsFallback() async {
    let engine = CommandRouter(handlers: [
        "list-sessions": { @Sendable _ in ["handled_by": .string("engine")] },
    ])
    let daemon = CommandRouter(handlers: [
        "list-sessions": { @Sendable _ in ["handled_by": .string("daemon")] },
    ], fallback: engine)

    let resp = await daemon.handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
    #expect(resp.result?["handled_by"] == .string("daemon"))
}

@Test func unknownWithNoFallbackStillErrors() async {
    let router = CommandRouter(handlers: ["a": { @Sendable _ in [:] }])
    let resp = await router.handle(request: JSONRPCRequest(id: 1, method: "nope"))
    #expect(resp.error?.code == RPCErrorCode.methodNotFound)
}
