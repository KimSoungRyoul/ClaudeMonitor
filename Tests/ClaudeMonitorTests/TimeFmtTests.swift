//
//  TimeFmtTests.swift
//  ClaudeMonitorTests
//
//  남은 시간 문자열/색상. 팝오버가 30초마다 다시 그리는 부분이라 경계값이 중요하다.
//

import XCTest
import SwiftUI
@testable import ClaudeMonitor

final class TimeFmtTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        L.lang = .en          // 문자열 단정은 영어 기준으로 (테스트가 로케일에 흔들리지 않게)
    }

    override func tearDown() {
        L.lang = .ko
        super.tearDown()
    }

    func testRemainingBuckets() {
        XCTAssertEqual(TimeFmt.remaining(now.addingTimeInterval(90 * 60), now: now), "1h 30m left")
        XCTAssertEqual(TimeFmt.remaining(now.addingTimeInterval(25 * 60), now: now), "25m left")
        XCTAssertEqual(TimeFmt.remaining(now.addingTimeInterval(3 * 86_400 + 3600), now: now), "3d 1h left")
    }

    func testRemainingCompactDropsTheSuffix() {
        XCTAssertEqual(TimeFmt.remainingCompact(now.addingTimeInterval(90 * 60), now: now), "1h 30m")
        XCTAssertEqual(TimeFmt.remainingCompact(now.addingTimeInterval(2 * 86_400), now: now), "2d 0h")
    }

    /// 이미 지난 리셋 시각과 nil 은 크래시 없이 안내 문구로 떨어져야 한다.
    func testPastAndMissingDates() {
        XCTAssertEqual(TimeFmt.remaining(now.addingTimeInterval(-60), now: now), "resetting soon")
        XCTAssertEqual(TimeFmt.remainingCompact(now.addingTimeInterval(-60), now: now), "soon")
        XCTAssertEqual(TimeFmt.remaining(nil, now: now), "-")
        XCTAssertEqual(TimeFmt.remainingCompact(nil, now: now), "-")
    }

    /// 5시간 주기: 1시간 미만이면 빨강.
    func testShortCycleColor() {
        XCTAssertEqual(TimeFmt.remainingColor(now.addingTimeInterval(59 * 60), longCycle: false, now: now),
                       Color(hex: 0xFF3B30))
        XCTAssertEqual(TimeFmt.remainingColor(now.addingTimeInterval(61 * 60), longCycle: false, now: now),
                       Color(hex: 0x34C759))
    }

    /// 7일 주기: 1일 미만 빨강 → 2일 미만 금색 → 그 외 초록.
    func testLongCycleColor() {
        XCTAssertEqual(TimeFmt.remainingColor(now.addingTimeInterval(23 * 3600), longCycle: true, now: now),
                       Color(hex: 0xFF3B30))
        XCTAssertEqual(TimeFmt.remainingColor(now.addingTimeInterval(36 * 3600), longCycle: true, now: now),
                       Color(hex: 0xE0A500))
        XCTAssertEqual(TimeFmt.remainingColor(now.addingTimeInterval(5 * 86_400), longCycle: true, now: now),
                       Color(hex: 0x34C759))
        XCTAssertEqual(TimeFmt.remainingColor(nil, longCycle: true, now: now), Color.secondary)
    }

    /// 리셋 시각 문자열은 언어를 따라간다(포매터 캐시가 언어 전환을 반영하는지 포함).
    func testResetStringsFollowLanguage() {
        let date = now.addingTimeInterval(3600)
        L.lang = .en
        let english = TimeFmt.resetShort(date)
        L.lang = .ko
        let korean = TimeFmt.resetShort(date)
        XCTAssertNotEqual(english, korean)
        // 한국어 시각은 항상 오전/오후를 포함한다 (날짜 부분의 표기는 로케일 데이터에 맡긴다).
        XCTAssertTrue(korean.contains("오전") || korean.contains("오후"), "unexpected: \(korean)")
        XCTAssertTrue(english.contains("AM") || english.contains("PM"), "unexpected: \(english)")
    }

    func testMissingDateFallsBackToHint() {
        L.lang = .en
        XCTAssertEqual(TimeFmt.resetShort(nil), "Shown after first use")
        XCTAssertEqual(TimeFmt.resetLong(nil), "Shown after first use")
    }
}
