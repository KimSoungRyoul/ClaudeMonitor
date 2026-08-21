//
//  APIErrorMappingTests.swift
//  ClaudeMonitorTests
//
//  응답 → 에러 분류 검증. 핵심은 조직 단위 요청의 404 다:
//  claude.ai 는 "세션 키에 없는 조직" 을 존재하지 않는 uuid 와 똑같이 not_found_error(404) 로 답한다.
//  이걸 그냥 HTTP 오류로 흘리면 계정 행에 "HTTP 오류 (404)" 만 뜨고 복구 버튼도, Chrome 자동 복구도
//  걸리지 않는다(다른 로그인의 키를 들고 있는 상태라 새로고침으로는 영원히 안 풀린다).
//

import XCTest
@testable import ClaudeMonitor

final class APIErrorMappingTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    private let notFound = """
    {"type":"error","error":{"type":"not_found_error","message":"Not found",
     "details":{"error_visibility":"user_facing"}},"request_id":"req_1"}
    """
    private let permission = """
    {"type":"error","error":{"type":"permission_error","message":"Invalid authorization for organization"},
     "request_id":"req_2"}
    """

    /// 던진 에러를 꺼내 본다 (ClaudeAPIError 는 Equatable 이 아니라 XCTAssertThrowsError 로 받는다).
    private func error(status: Int, body: String, orgScoped: Bool) -> ClaudeAPIError? {
        do {
            _ = try ClaudeAPI.validate(status: status, data: data(body), orgScoped: orgScoped)
            return nil
        } catch let e as ClaudeAPIError {
            return e
        } catch {
            return nil
        }
    }

    func testOrgScoped404IsOrganizationNotFound() {
        guard let e = error(status: 404, body: notFound, orgScoped: true) else {
            return XCTFail("404 should throw")
        }
        guard case .organizationNotFound = e else { return XCTFail("got \(e)") }
        XCTAssertTrue(e.needsReauth)     // 행에 복구 버튼 + Chrome 자동 복구 대상
        XCTAssertFalse(e.isTransient)    // 재시도로는 안 풀리니 백오프 대상도 아니다
    }

    /// 본문이 비어 있어도(혹은 JSON 이 아니어도) 조직 단위 요청의 404 는 같은 뜻이다.
    func testOrgScoped404WithoutErrorBody() {
        guard let e = error(status: 404, body: "{}", orgScoped: true) else {
            return XCTFail("404 should throw")
        }
        guard case .organizationNotFound = e else { return XCTFail("got \(e)") }
    }

    /// 조직 단위가 아닌 요청(/organizations 등)의 404 는 그대로 HTTP 오류다 — 세션 문제로 오인하지 않는다.
    func testNonOrgScoped404StaysHTTPError() {
        guard let e = error(status: 404, body: notFound, orgScoped: false) else {
            return XCTFail("404 should throw")
        }
        guard case .http(let code) = e else { return XCTFail("got \(e)") }
        XCTAssertEqual(code, 404)
    }

    func testPermissionErrorIsUnauthorized() {
        guard let e = error(status: 403, body: permission, orgScoped: true) else {
            return XCTFail("403 should throw")
        }
        guard case .unauthorized = e else { return XCTFail("got \(e)") }
        XCTAssertTrue(e.needsReauth)
    }

    func testChallengeHTMLIsCloudflareBlocked() {
        guard let e = error(status: 403, body: "<html><body>Just a moment…</body></html>", orgScoped: true) else {
            return XCTFail("HTML should throw")
        }
        guard case .cloudflareBlocked = e else { return XCTFail("got \(e)") }
        XCTAssertTrue(e.isTransient)
    }

    func testSuccessPassesBodyThrough() throws {
        let body = #"{"five_hour":{"utilization":1.0,"resets_at":null}}"#
        let out = try ClaudeAPI.validate(status: 200, data: data(body), orgScoped: true)
        XCTAssertEqual(out, data(body))
    }

    // MARK: - API 전용 조직 걸러내기

    /// console.anthropic.com 전용 조직(`api`)은 /usage 가 없어 계정으로 담으면 영원히 실패한다.
    func testReportsUsageFiltersAPIOnlyOrganizations() {
        func org(_ caps: [String]?) -> Organization {
            Organization(uuid: "u", name: "n", capabilities: caps)
        }
        XCTAssertFalse(org(["api"]).reportsUsage)
        XCTAssertFalse(org(["api", "api_individual"]).reportsUsage)
        XCTAssertTrue(org(["chat", "raven"]).reportsUsage)
        XCTAssertTrue(org(["raven_enterprise", "raven", "chat", "compliance_logging"]).reportsUsage)
        // 판단 근거가 없으면 막지 않는다 (응답 형태가 바뀌어도 계정이 통째로 사라지지 않게)
        XCTAssertTrue(org(nil).reportsUsage)
        XCTAssertTrue(org([]).reportsUsage)
    }
}
