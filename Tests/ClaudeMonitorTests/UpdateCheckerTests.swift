//
//  UpdateCheckerTests.swift
//  ClaudeMonitorTests
//
//  릴리즈 태그 비교. 여기서 틀리면 사용자가 업데이트 배지를 못 보거나, 이미 최신인데 계속 보게 된다.
//

import XCTest
@testable import ClaudeMonitor

final class UpdateCheckerTests: XCTestCase {

    func testParseVersionAcceptsTagAndPlainForms() {
        XCTAssertEqual(UpdateChecker.parseVersion("v0.1.8"), [0, 1, 8])
        XCTAssertEqual(UpdateChecker.parseVersion("0.1.8"), [0, 1, 8])
        XCTAssertEqual(UpdateChecker.parseVersion("v1.2"), [1, 2])
        XCTAssertEqual(UpdateChecker.parseVersion("v2.0.0-beta.1"), [2, 0, 0])   // 프리릴리즈 꼬리표 무시
        XCTAssertEqual(UpdateChecker.parseVersion("v0.1.x"), [0, 1, 0])          // 숫자가 아니면 0
    }

    func testIsOlderComparesComponentwise() {
        XCTAssertTrue(UpdateChecker.isOlder([0, 1, 7], than: [0, 1, 8]))
        XCTAssertTrue(UpdateChecker.isOlder([0, 9, 9], than: [1, 0, 0]))
        XCTAssertFalse(UpdateChecker.isOlder([0, 1, 8], than: [0, 1, 8]))        // 같으면 최신
        XCTAssertFalse(UpdateChecker.isOlder([0, 2, 0], than: [0, 1, 9]))
    }

    /// 길이가 다른 버전: 빠진 자리는 0 으로 채워 비교한다.
    func testIsOlderHandlesDifferentLengths() {
        XCTAssertTrue(UpdateChecker.isOlder([0, 1], than: [0, 1, 1]))
        XCTAssertFalse(UpdateChecker.isOlder([0, 1, 0], than: [0, 1]))
        XCTAssertFalse(UpdateChecker.isOlder([1], than: [1, 0, 0]))
    }

    /// 10 이상 자리를 문자열로 비교하면 "0.1.10" < "0.1.9" 가 되어버린다.
    func testTwoDigitPatchIsNewerThanSingleDigit() {
        XCTAssertTrue(UpdateChecker.isOlder(UpdateChecker.parseVersion("v0.1.9"),
                                            than: UpdateChecker.parseVersion("v0.1.10")))
    }
}
