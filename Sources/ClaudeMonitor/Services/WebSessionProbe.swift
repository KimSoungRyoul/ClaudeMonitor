//
//  WebSessionProbe.swift
//  ClaudeMonitor
//
//  개발 전용 검증 도구. WebSession(WKWebView fetch)이 Cloudflare managed challenge 를
//  실제로 통과하는지 확인한다. 잘못된 sessionKey 여도 응답이 HTML("Just a moment")이 아니라
//  JSON(401/403)이면 봇 차단 우회가 성공한 것이다 (사용자 시크릿 없이 핵심 가설 검증).
//

#if DEBUG
import AppKit
import Foundation

@MainActor
enum WebSessionProbe {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let key = ProcessInfo.processInfo.environment["CTM_TEST_KEY"] ?? "sk-ant-sid01-invalid-probe-key"
        let url = "https://claude.ai/api/organizations"
        /// 측정용 유지 시간 (CTM_PROBE_HOLD=<초>). 안전장치 타임아웃은 이보다 길어야 한다.
        let hold = ProcessInfo.processInfo.environment["CTM_PROBE_HOLD"].flatMap(Double.init) ?? 0

        Task { @MainActor in
            print("PROBE: requesting \(url) (key=\(key.prefix(16))…)")
            do {
                let (status, data) = try await WebSession.shared.request(urlString: url, sessionKey: key)
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count)B>"
                let isHTML = body.contains("<html") || body.contains("Just a moment")
                print("PROBE: status=\(status) bytes=\(data.count) html=\(isHTML)")
                print("PROBE: body head: \(body.prefix(240))")
                if isHTML {
                    print("PROBE: ❌ STILL CHALLENGED (Cloudflare HTML)")
                } else {
                    print("PROBE: ✅ BYPASS OK (got JSON, not the challenge page)")
                }
                // 숨은 호스트 윈도우가 실제로 안 보이는 상태인지 확인 (바탕화면에 박히는 버그 회귀 방지)
                print("PROBE: host window \(WebSession.shared.hostWindowDiagnostics)")
                if WebSession.shared.hostWindowVisibleToUser {
                    print("PROBE: ❌ HOST WINDOW VISIBLE (would show claude.ai login on screen)")
                } else {
                    print("PROBE: ✅ HOST WINDOW HIDDEN (offscreen + transparent)")
                }
                // OS 가 윈도우를 화면 안으로 끌어오는 상황(디스플레이 변경 등)에서 다시 화면 밖으로 돌아가는지
                WebSession.shared.debugForceOnScreen()
                try? await Task.sleep(nanoseconds: 500_000_000)
                print("PROBE: after forced on-screen → \(WebSession.shared.hostWindowDiagnostics)")
                if WebSession.shared.hostWindowVisibleToUser {
                    print("PROBE: ❌ NOT RE-PARKED (window stuck on screen)")
                } else {
                    print("PROBE: ✅ RE-PARKED OFFSCREEN")
                }

                // 배치 요청(Promise.all): 여러 URL 이 한 번의 왕복으로 순서대로 돌아오는지
                let batch = try await WebSession.shared.requestMany(
                    urlStrings: ["https://claude.ai/api/organizations",
                                 "https://claude.ai/api/organizations?probe=2"],
                    sessionKey: key)
                print("PROBE: batch statuses=\(batch.map(\.status)) sizes=\(batch.map(\.data.count))")
                print(batch.count == 2 ? "PROBE: ✅ BATCH OK (one round trip, ordered)"
                                       : "PROBE: ❌ BATCH returned \(batch.count) results")

                // 요청마다 sessionKey 쿠키는 정확히 하나여야 한다. 두 개가 남으면(서버가 내려준 것 +
                // 우리가 넣은 것) 다른 계정으로 인증돼 멀쩡한 조직이 404 로 보인다.
                let cookies = await WebSession.shared.debugCookieSummary()
                let sessionCookies = cookies.split(separator: "|").filter { $0.contains("sessionKey@") }
                print("PROBE: cookies = \(cookies)")
                print(sessionCookies.count == 1 ? "PROBE: ✅ ONE SESSION COOKIE"
                                                : "PROBE: ❌ \(sessionCookies.count) session cookies (인증 혼선)")

                // 웹뷰 나이 제한: 오래 살아남은 컨텍스트는 다음 요청 전에 버려져야 한다.
                // (새로고침 주기가 짧으면 유휴 정리가 매번 취소돼 웹뷰가 영원히 사는 문제)
                let before = WebSession.shared.webViewGeneration
                WebSession.shared.debugAgeWebView(by: 3600)
                _ = try? await WebSession.shared.request(urlString: url, sessionKey: key)
                let after = WebSession.shared.webViewGeneration
                print(after > before ? "PROBE: ✅ STALE WEBVIEW RECYCLED (gen \(before) → \(after))"
                                     : "PROBE: ❌ STALE WEBVIEW REUSED (gen \(before))")
            } catch {
                print("PROBE: error: \(error)")
            }
            // 유휴 정리: 웹뷰/호스트 윈도우(그리고 WebKit 프로세스들)가 실제로 반납되는지
            if ProcessInfo.processInfo.environment["CTM_PROBE_TEARDOWN"] != "0" {
                WebSession.shared.debugTeardownNow()
                print("PROBE: after teardown → \(WebSession.shared.hostWindowDiagnostics)")
            }
            // CTM_PROBE_HOLD=<초>: 프로세스를 살려둬 유휴 정리/메모리 반납을 관찰하는 용도.
            if hold > 0 {
                print("PROBE: holding \(Int(hold))s for measurement…")
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                print("PROBE: after hold → \(WebSession.shared.hostWindowDiagnostics)")
            }
            exit(0)
        }
        // 안전장치: 무한 대기 방지. 측정용 유지 시간(CTM_PROBE_HOLD)보다 길어야
        // 관찰 도중에 프로세스를 죽이지 않는다.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((60 + hold) * 1_000_000_000))
            print("PROBE: timeout")
            exit(2)
        }
        app.run()
    }

    /// 실제 계정 구성(조직 → sessionKey 매핑 JSON)으로 AppState.performRefresh 의 조회 부분을
    /// 그대로 재현한다. 사용법: CTM_REFRESH_SIM=/path/to/{"orgId":"sk-ant-…"}.json
    static func refreshSim() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let path = ProcessInfo.processInfo.environment["CTM_REFRESH_SIM"],
              let data = FileManager.default.contents(atPath: path),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            print("SIM: CTM_REFRESH_SIM=<orgId→sessionKey json>"); exit(2)
        }
        let rounds = ProcessInfo.processInfo.environment["CTM_SIM_ROUNDS"].flatMap(Int.init) ?? 2

        Task { @MainActor in
            var groups: [String: [String]] = [:]
            for (org, key) in mapping { groups[key, default: []].append(org) }
            print("SIM: \(mapping.count) orgs in \(groups.count) key groups")
            let interval = ProcessInfo.processInfo.environment["CTM_SIM_INTERVAL"].flatMap(Double.init) ?? 0
            for round in 1...rounds {
                if round > 1, interval > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                print("SIM: === round \(round) (t+\(Int(Double(round - 1) * interval))s) ===")
                for (key, orgs) in groups {
                    let results = await ClaudeAPI.shared.fetchUsages(organizationIds: orgs, sessionKey: key)
                    var ok = 0
                    var errs: [String: Int] = [:]
                    for org in orgs {
                        switch results[org] {
                        case .success: ok += 1
                        case .failure(let e): errs["\(e)", default: 0] += 1
                        case nil: errs["nil", default: 0] += 1
                        }
                    }
                    print("SIM: key …\(key.suffix(4)) → \(ok)/\(orgs.count) ok, errors=\(errs)")
                }
            }
            exit(0)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            print("SIM: timeout"); exit(2)
        }
        app.run()
    }

    /// 여러 계정(sessionKey)을 한 프로세스에서 번갈아 쓸 때 인증이 섞이지 않는지 검증한다.
    /// 사용법: CTM_MULTIKEY_TEST=1 CTM_TEST_KEY=<A> CTM_TEST_KEY2=<B> ./.build/debug/ClaudeMonitor
    static func multiKey() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        guard let a = env["CTM_TEST_KEY"], let b = env["CTM_TEST_KEY2"], !a.isEmpty, !b.isEmpty else {
            print("MULTI: set CTM_TEST_KEY and CTM_TEST_KEY2")
            exit(2)
        }

        Task { @MainActor in
            func cookies(_ label: String) async {
                print("MULTI: cookies after \(label): \(await WebSession.shared.debugCookieSummary())")
            }
            func check(_ label: String, ids: [String], key: String) async -> Int {
                let r = await ClaudeAPI.shared.fetchUsages(organizationIds: ids, sessionKey: key)
                let ok = r.values.filter { if case .success = $0 { return true } else { return false } }.count
                let firstError = r.values.compactMap { if case .failure(let e) = $0 { return "\(e)" } else { return nil } }.first
                print("MULTI: \(label) → \(ok)/\(ids.count) ok\(firstError.map { " (first error: \($0))" } ?? "")")
                return ok
            }

            guard let orgsA = try? await ClaudeAPI.shared.fetchOrganizations(sessionKey: a),
                  let orgsB = try? await ClaudeAPI.shared.fetchOrganizations(sessionKey: b) else {
                print("MULTI: org fetch failed"); exit(2)
            }
            let idsA = orgsA.filter(\.reportsUsage).map(\.uuid)
            let idsB = orgsB.filter(\.reportsUsage).map(\.uuid)
            print("MULTI: A=\(idsA.count) orgs, B=\(idsB.count) orgs")
            await cookies("org fetches")

            // 같은 웹뷰를 계속 쓰면서 키를 번갈아 조회했을 때, 조직 목록이 항상 그 키의 것인지.
            // (쿠키 주입이 한 번이라도 늦으면 이전 키의 계정으로 인증돼 조직 목록이 뒤바뀐다)
            let laps = ProcessInfo.processInfo.environment["CTM_MULTIKEY_LAPS"].flatMap(Int.init) ?? 0
            for lap in 0..<laps {
                let x = try? await ClaudeAPI.shared.fetchOrganizations(sessionKey: a)
                let y = try? await ClaudeAPI.shared.fetchOrganizations(sessionKey: b)
                let xn = x?.count ?? -1, yn = y?.count ?? -1
                if xn != orgsA.count || yn != orgsB.count {
                    print("MULTI: ❌ lap \(lap): A=\(xn)(기대 \(orgsA.count)) B=\(yn)(기대 \(orgsB.count)) — 인증이 뒤바뀜")
                } else if lap % 5 == 0 {
                    print("MULTI: lap \(lap) ok (A=\(xn) B=\(yn))")
                }
            }

            let a1 = await check("A alone", ids: idsA, key: a)
            await cookies("A")
            _ = await check("B", ids: idsB, key: b)
            await cookies("B")
            let a2 = await check("A again (after B)", ids: idsA, key: a)
            await cookies("A again")

            print(a1 == idsA.count && a2 == idsA.count
                  ? "MULTI: ✅ 키를 번갈아 써도 인증이 섞이지 않는다"
                  : "MULTI: ❌ 키 전환 후 인증이 섞였다 (A: \(a1) → \(a2))")
            exit(a1 == idsA.count && a2 == idsA.count ? 0 : 1)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            print("MULTI: timeout"); exit(2)
        }
        app.run()
    }

    /// 실제 usage API 응답 원본 JSON 을 덤프한다(필드명 확인용).
    /// 사용법: CTM_USAGE_DUMP=1 CTM_TEST_KEY=sk-ant-... ./.build/debug/ClaudeMonitor
    static func dumpUsage() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        guard let key = ProcessInfo.processInfo.environment["CTM_TEST_KEY"], !key.isEmpty else {
            print("DUMP: set CTM_TEST_KEY=sk-ant-...")
            exit(2)
        }
        let base = "https://claude.ai/api"

        Task { @MainActor in
            // CTM_PROBE_ORG=<uuid>: 이 세션에 **없는** 조직을 일부러 찔러 본다.
            // (404 not_found_error 로 오는지, 403 permission_error 로 오는지 확인 — 오류 매핑의 근거)
            if let foreign = ProcessInfo.processInfo.environment["CTM_PROBE_ORG"] {
                for suffix in ["usage", "overage_spend_limit"] {
                    if let raw = try? await WebSession.shared.request(
                        urlString: "\(base)/organizations/\(foreign)/\(suffix)", sessionKey: key) {
                        let body = String(data: raw.data, encoding: .utf8) ?? "<binary>"
                        print("FOREIGN \(suffix): status=\(raw.status) body=\(body.prefix(240))")
                    } else {
                        print("FOREIGN \(suffix): request threw")
                    }
                }
                exit(0)
            }
            do {
                let orgs = try await ClaudeAPI.shared.fetchOrganizations(sessionKey: key)
                print("DUMP: \(orgs.count) organizations")
                for org in orgs {
                    // 요금제 배지는 capabilities 로 추정한다 — 실제 값과 추정 결과를 같이 찍어 검증한다.
                    print("  uuid=\(org.uuid) plan=\(org.plan.label) capabilities=\(org.capabilities ?? [])")
                    do {
                        let u = try await ClaudeAPI.shared.fetchUsage(organizationId: org.uuid, sessionKey: key)
                        let five = u.fiveHour.map { "\(Int($0.percentage))%" } ?? "—"
                        let seven = u.sevenDay.map { "\(Int($0.percentage))%" } ?? "—"
                        let models = u.models.map { "\($0.name)=\(Int($0.usage.percentage))%" }.joined(separator: ", ")
                        let extra = u.extra.map { "extra \($0.compactUsed)/\($0.currencySymbol)\(Int($0.limit))" } ?? "no-extra"
                        print("• \(org.name): 5h=\(five) 7d=\(seven) | models=[\(models.isEmpty ? "none" : models)] | \(extra)")
                    } catch {
                        print("• \(org.name): \(error.localizedDescription)")
                        // 실패했을 때는 원본 응답을 그대로 보여준다 — "왜 404 인가"(엔드포인트가 바뀐 것인지,
                        // 이 세션에 그 조직이 없는 것인지)는 상태코드+본문을 봐야 갈린다.
                        if let raw = try? await WebSession.shared.request(
                            urlString: "\(base)/organizations/\(org.uuid)/usage", sessionKey: key) {
                            let body = String(data: raw.data, encoding: .utf8) ?? "<binary>"
                            print("    raw: status=\(raw.status) body=\(body.prefix(300))")
                        }
                    }
                }
                // 앱이 실제로 쓰는 경로는 배치 조회(fetchUsages)다 — 단건은 되는데 배치가 틀리면
                // 화면 전체가 실패하므로, 같은 키로 두 경로를 나란히 확인한다.
                let ids = orgs.filter(\.reportsUsage).map(\.uuid)
                print("DUMP: --- batched fetchUsages(\(ids.count) orgs) ---")
                let batched = await ClaudeAPI.shared.fetchUsages(organizationIds: ids, sessionKey: key)
                for org in orgs where org.reportsUsage {
                    switch batched[org.uuid] {
                    case .success(let u):
                        print("  ✅ \(org.name): 5h=\(u.fiveHour.map { "\(Int($0.percentage))%" } ?? "—")")
                    case .failure(let e):
                        print("  ❌ \(org.name): \(e)")
                    case nil:
                        print("  ❌ \(org.name): (no result)")
                    }
                }
            } catch {
                print("DUMP: org fetch error: \(error)")
            }
            exit(0)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            print("DUMP: timeout")
            exit(2)
        }
        app.run()
    }
}
#endif
