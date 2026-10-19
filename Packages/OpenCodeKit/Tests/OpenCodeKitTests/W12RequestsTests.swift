import XCTest
@testable import OpenCodeTransport

/// W12 request shapes (docs/api-contract.md W12/W13): operation IDs,
/// paths, required-vs-optional query params, and the DTO decodes the
/// mobile scope depends on — the nullable base, the wire `default`
/// branch key, and the exact three-case status enum.
final class W12RequestsTests: XCTestCase {
    private func query(_ request: APIRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: request.query.map { ($0.key, $0.value) })
    }

    func testSessionDiffOmitsOptionalParamsSoHostDefaultsApply() {
        let request = W12Requests.sessionDiff(sessionID: "ses_1")
        XCTAssertEqual(request.operationID, "session.diff")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/session/ses_1/diff")
        XCTAssertTrue(
            request.query.isEmpty,
            "from/to/context are omitted — the host applies its documented defaults"
        )
    }

    func testSessionDiffCarriesTurnRangeAndContextInOrder() {
        let request = W12Requests.sessionDiff(
            sessionID: "ses_1", from: "msg_a", to: "msg_b", context: "3"
        )
        XCTAssertEqual(request.query.map(\.key), ["from", "to", "context"])
        XCTAssertEqual(query(request), ["from": "msg_a", "to": "msg_b", "context": "3"])
    }

    func testVcsInfoStatusAndBaseCarryOnlyTheLocation() {
        for (request, operationID, path) in [
            (W12Requests.vcsInfo(directory: "/srv/demo"), "vcs.get", "/api/vcs"),
            (W12Requests.vcsStatus(directory: "/srv/demo"), "vcs.status", "/api/vcs/status"),
            (W12Requests.vcsBase(directory: "/srv/demo"), "vcs.base", "/api/vcs/base"),
        ] {
            XCTAssertEqual(request.operationID, operationID)
            XCTAssertEqual(request.method, .get)
            XCTAssertEqual(request.path, path)
            XCTAssertEqual(request.query.map(\.key), ["location[directory]"])
            XCTAssertEqual(query(request)["location[directory]"], "/srv/demo")
        }
    }

    func testVcsCallsOmitTheLocationEntirelyWhenNoDirectoryIsGiven() {
        for request in [
            W12Requests.vcsInfo(),
            W12Requests.vcsStatus(),
            W12Requests.vcsBase(),
            W12Requests.vcsDiff(mode: .working),
        ] {
            XCTAssertTrue(
                request.query.filter { $0.key == "location[directory]" }.isEmpty,
                "an absent directory omits the pair — the host applies its own location default"
            )
        }
    }

    func testVcsDiffAlwaysCarriesModeAndOmitsAbsentBaseAndContext() {
        let request = W12Requests.vcsDiff(directory: "/srv/demo", mode: .branch)
        XCTAssertEqual(request.operationID, "vcs.diff")
        XCTAssertEqual(request.path, "/api/vcs/diff")
        XCTAssertEqual(request.query.map(\.key), ["location[directory]", "mode"])
        XCTAssertEqual(query(request)["mode"], "branch")
    }

    func testVcsDiffCarriesExplicitBaseAndContextAfterMode() {
        let request = W12Requests.vcsDiff(
            directory: "/srv/demo", mode: .committed, base: "HEAD~2", context: "3"
        )
        XCTAssertEqual(request.query.map(\.key), ["location[directory]", "mode", "base", "context"])
        XCTAssertEqual(query(request)["base"], "HEAD~2")
        XCTAssertEqual(query(request)["context"], "3")
    }

    func testSessionDiffResponseDecodesHostCountsAndStatus() throws {
        let body = #"{"data":[{"file":"src/main.py","patch":"--- a/src/main.py\n+++ b/src/main.py\n","additions":3,"deletions":1,"status":"modified"}]}"#
        let response = try OpenCodeAPI.decoder.decode(
            SessionDiffResponse.self, from: Data(body.utf8)
        )
        XCTAssertEqual(response.data, [
            FileDiff.Info(
                file: "src/main.py",
                patch: "--- a/src/main.py\n+++ b/src/main.py\n",
                additions: 3,
                deletions: 1,
                status: .modified
            ),
        ])
    }

    func testVcsBaseResponseDecodesNullAsUnavailableNotFailure() throws {
        let body = #"{"location":{"directory":"/srv/demo"},"data":null}"#
        let response = try OpenCodeAPI.decoder.decode(
            LocationEnvelope<Vcs.Base?>.self, from: Data(body.utf8)
        )
        XCTAssertNil(
            response.data,
            "a null base is a distinct unavailable state, never an error or an empty diff"
        )
    }

    func testVcsInfoResponseDecodesTheDefaultBranchKey() throws {
        let body = #"{"location":{"directory":"/srv/demo"},"data":{"provider":"git","branch":{"current":"demo-feature","default":"main"}}}"#
        let response = try OpenCodeAPI.decoder.decode(
            LocationEnvelope<Vcs.Info>.self, from: Data(body.utf8)
        )
        XCTAssertEqual(response.data.provider, "git")
        XCTAssertEqual(response.data.branch.current, "demo-feature")
        XCTAssertEqual(
            response.data.branch.defaultBranch, "main",
            "the wire key `default` maps to defaultBranch"
        )
    }

    func testVcsStatusRowDecodesWithoutAPatch() throws {
        let body = #"{"location":{"directory":"/srv/demo"},"data":[{"file":"src/main.py","additions":1,"deletions":1,"status":"modified"}]}"#
        let response = try OpenCodeAPI.decoder.decode(
            LocationEnvelope<[Vcs.FileStatus]>.self, from: Data(body.utf8)
        )
        XCTAssertEqual(response.data, [
            Vcs.FileStatus(file: "src/main.py", additions: 1, deletions: 1, status: .modified),
        ])
    }

    func testDiffStatusEnumRejectsCasesOutsideThePinnedThree() {
        XCTAssertNil(
            FileDiff.Status(rawValue: "renamed"),
            "the pinned enum is exactly added/deleted/modified"
        )
        XCTAssertEqual(Vcs.Source(rawValue: "reflog"), .reflog)
        XCTAssertEqual(Vcs.Source(rawValue: "default"), .repositoryDefault)
        XCTAssertNil(Vcs.Source(rawValue: "guessed"))
    }
}
