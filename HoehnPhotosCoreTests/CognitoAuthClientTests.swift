import XCTest
@testable import HoehnPhotosCore

// MARK: - MockURLProtocol

/// Intercepts URLSession requests in unit tests. Configure via `stub(statusCode:body:)`.
final class MockURLProtocol: URLProtocol {

    static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - CognitoAuthClientTests

final class CognitoAuthClientTests: XCTestCase {

    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        CognitoAuthClient._session = mockSession
    }

    override func tearDown() {
        CognitoAuthClient._session = .shared
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func stubCognitoResponse(statusCode: Int, body: [String: Any]) {
        let url = URL(string: "https://cognito-idp.us-east-1.amazonaws.com/")!
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: statusCode,
                                       httpVersion: nil, headerFields: nil)!
        MockURLProtocol.handler = { _ in (data, response) }
    }

    // MARK: - Tests

    func testInitiateAuthReturnsTokens() async throws {
        stubCognitoResponse(statusCode: 200, body: [
            "AuthenticationResult": [
                "IdToken": "id.token.here",
                "RefreshToken": "refresh.token.here",
                "AccessToken": "access.token.here",
            ]
        ])

        let result = try await CognitoAuthClient.initiateUserPasswordAuth(
            username: "user@example.com", password: "Password1!")

        if case .tokens(let id, let refresh) = result {
            XCTAssertEqual(id, "id.token.here")
            XCTAssertEqual(refresh, "refresh.token.here")
        } else {
            XCTFail("Expected .tokens, got \(result)")
        }
    }

    func testInitiateAuthReturnsNewPasswordChallenge() async throws {
        stubCognitoResponse(statusCode: 200, body: [
            "ChallengeName": "NEW_PASSWORD_REQUIRED",
            "Session": "session-string-abc"
        ])

        let result = try await CognitoAuthClient.initiateUserPasswordAuth(
            username: "user@example.com", password: "TempPass1!")

        if case .newPasswordRequired(let session) = result {
            XCTAssertEqual(session, "session-string-abc")
        } else {
            XCTFail("Expected .newPasswordRequired, got \(result)")
        }
    }

    func testInitiateAuthThrowsOnServerError() async throws {
        stubCognitoResponse(statusCode: 400, body: [
            "__type": "NotAuthorizedException",
            "message": "Incorrect username or password."
        ])

        do {
            _ = try await CognitoAuthClient.initiateUserPasswordAuth(
                username: "bad@example.com", password: "wrong")
            XCTFail("Expected AuthError.server to be thrown")
        } catch CognitoAuthClient.AuthError.server(let status, let type, let message) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(type, "NotAuthorizedException")
            XCTAssertEqual(message, "Incorrect username or password.")
        }
    }

    func testInitiateAuthThrowsOnMissingRefreshToken() async throws {
        stubCognitoResponse(statusCode: 200, body: [
            "AuthenticationResult": ["IdToken": "id.token"]
            // RefreshToken intentionally omitted
        ])

        do {
            _ = try await CognitoAuthClient.initiateUserPasswordAuth(
                username: "user@example.com", password: "Pass1!")
            XCTFail("Expected AuthError.missingField to be thrown")
        } catch CognitoAuthClient.AuthError.missingField(let field) {
            XCTAssertEqual(field, "RefreshToken")
        }
    }

    func testRespondToChallengeReturnsTokens() async throws {
        stubCognitoResponse(statusCode: 200, body: [
            "AuthenticationResult": [
                "IdToken": "new.id.token",
                "RefreshToken": "new.refresh.token",
            ]
        ])

        let (id, refresh) = try await CognitoAuthClient.respondToNewPasswordChallenge(
            username: "user@example.com", newPassword: "NewPass1!", session: "sess")

        XCTAssertEqual(id, "new.id.token")
        XCTAssertEqual(refresh, "new.refresh.token")
    }

    func testAuthErrorUserMessages() {
        XCTAssertEqual(
            CognitoAuthClient.AuthError.invalidConfig.userMessage,
            "Invalid Cognito configuration.")
        XCTAssertEqual(
            CognitoAuthClient.AuthError.malformedResponse.userMessage,
            "Unexpected response from Cognito.")
        XCTAssertEqual(
            CognitoAuthClient.AuthError.missingField("Session").userMessage,
            "Cognito response missing 'Session'.")
        XCTAssertEqual(
            CognitoAuthClient.AuthError.server(status: 400, type: nil, message: "Bad creds").userMessage,
            "Bad creds")
        XCTAssertEqual(
            CognitoAuthClient.AuthError.server(status: 400, type: "UserLambdaValidationException", message: nil).userMessage,
            "Sign-in failed: UserLambdaValidationException")
        XCTAssertEqual(
            CognitoAuthClient.AuthError.server(status: 500, type: nil, message: nil).userMessage,
            "Sign-in failed.")
    }
}
