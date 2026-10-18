import CoreGraphics
import Foundation
import Testing
@testable import PomoUI

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite struct DevicesClientTests {
    private func client(port: Int, _ h: @escaping StubProtocol.Handler) -> PomoClient {
        StubProtocol.register(port: port, h)
        return PomoClient(config: DaemonConfig(port: port, token: "tok"), session: StubProtocol.session())
    }

    @Test func devicesDecodes() async throws {
        let c = client(port: 50101) { req in
            #expect(req.httpMethod == "GET" && req.url?.path == "/v1/devices")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return .init(body: json(#"{"device_id":"aa","name":"mac","devices":[{"device_id":"bb","name":"phone","paired":true,"revoked":false},{"device_id":"cc","name":"old","paired":true,"revoked":true}]}"#))
        }
        let l = try await c.devices()
        #expect(l.deviceId == "aa" && l.name == "mac")
        #expect(l.devices == [DeviceInfo(deviceId: "bb", name: "phone"), DeviceInfo(deviceId: "cc", name: "old", revoked: true)])
    }

    @Test func pairOfferPostsAndDecodes() async throws {
        let c = client(port: 50102) { req in
            #expect(req.httpMethod == "POST" && req.url?.path == "/v1/pair/offer")
            return .init(body: json(#"{"ticket":"pomo-pair:abc","expires_ms":1234567}"#))
        }
        #expect(try await c.pairOffer() == PairOffer(ticket: "pomo-pair:abc", expiresMs: 1_234_567))
    }

    @Test func pairJoinSendsTicketAndOptionalName() async throws {
        let c = client(port: 50103) { req in
            let body = try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(req.url?.path == "/v1/pair/join")
            #expect(body?["ticket"] as? String == "pomo-pair:t")
            #expect(body?["name"] as? String == "air")
            return .init(body: json(#"{"device":{"device_id":"bb","name":"phone","paired":true,"revoked":false}}"#))
        }
        let d = try await c.pairJoin(ticket: "pomo-pair:t", name: "air")
        #expect(d.name == "phone")
        let c2 = client(port: 50104) { req in
            let body = try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["name"] == nil)
            return .init(body: json(#"{"device":{"device_id":"bb","name":"phone","paired":true,"revoked":false}}"#))
        }
        _ = try await c2.pairJoin(ticket: "t", name: "")
    }

    @Test func syncDecodesCountsAndPerPeerErrors() async throws {
        let c = client(port: 50105) { req in
            let body = try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(req.url?.path == "/v1/sync" && body?.isEmpty == true)
            return .init(body: json(#"{"synced":[{"device_id":"bb","sent":3,"received":1},{"device_id":"cc","error":"unreachable"}]}"#))
        }
        let r = try await c.sync(deviceId: nil)
        #expect(r == [PeerSync(deviceId: "bb", sent: 3, received: 1), PeerSync(deviceId: "cc", error: "unreachable")])
        let c2 = client(port: 50106) { req in
            let body = try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["device_id"] as? String == "bb")
            return .init(body: json(#"{"synced":[]}"#))
        }
        _ = try await c2.sync(deviceId: "bb")
    }

    @Test func revokePostsToDevicePath() async throws {
        let c = client(port: 50107) { req in
            #expect(req.httpMethod == "POST" && req.url?.path == "/v1/devices/bb/revoke")
            return .init(body: json(#"{"device":{"device_id":"bb","name":"phone","paired":true,"revoked":true}}"#))
        }
        #expect(try await c.revoke(deviceId: "bb").revoked)
    }

    @Test func syncDisabledSurfacesAsAPIError() async {
        let c = client(port: 50108) { _ in
            .init(status: 501, body: json(#"{"error":{"code":"sync_disabled","message":"sync is off"}}"#))
        }
        do { _ = try await c.devices(); Issue.record("expected error") }
        catch let e as APIError { #expect(e.status == 501 && e.code == "sync_disabled") }
        catch { Issue.record("wrong error \(error)") }
    }
}

final class FakeDevicesAPI: DevicesAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _list = DevicesList(deviceId: "aaaa1111", name: "My Mac")
    private var _offers: [PairOffer] = []
    private var _offerCalls = 0
    var error: Error?
    var syncResult: [PeerSync] = []
    var joinResult = DeviceInfo(deviceId: "dd", name: "Other")

    var list: DevicesList { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    var offers: [PairOffer] { get { lock.withLock { _offers } } set { lock.withLock { _offers = newValue } } }
    var offerCalls: Int { lock.withLock { _offerCalls } }

    func devices() async throws -> DevicesList { if let error { throw error }; return list }
    func pairOffer() async throws -> PairOffer {
        if let error { throw error }
        return lock.withLock {
            _offerCalls += 1
            return _offers.isEmpty ? PairOffer(ticket: "t\(_offerCalls)", expiresMs: 0) : _offers.removeFirst()
        }
    }
    func pairJoin(ticket: String, name: String?) async throws -> DeviceInfo {
        if let error { throw error }
        list.devices.append(joinResult)
        return joinResult
    }
    func sync(deviceId: String?) async throws -> [PeerSync] { if let error { throw error }; return syncResult }
    func revoke(deviceId: String) async throws -> DeviceInfo {
        if let error { throw error }
        var d = list.devices.first { $0.deviceId == deviceId }!
        d.revoked = true
        list.devices = list.devices.map { $0.deviceId == deviceId ? d : $0 }
        return d
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64
    init(_ now: Int64) { _now = now }
    var now: Int64 { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
}

@MainActor @Suite struct DevicesViewModelTests {
    private func make(_ api: FakeDevicesAPI, clock: MutableClock = MutableClock(1_000_000)) -> DevicesViewModel {
        DevicesViewModel(connector: { api }, clock: { clock.now })
    }

    @Test func errorMapping() {
        #expect(DevicesProblem.map(ConnectionError.unreachable("refused")) == .offline("refused"))
        #expect(DevicesProblem.map(APIError(status: 501, code: "sync_disabled", message: "x")) == .syncDisabled)
        #expect(DevicesProblem.map(APIError(status: 400, code: "bad_ticket", message: "x")).message.contains("not valid"))
        #expect(DevicesProblem.map(APIError(status: 409, code: "pairing_rejected", message: "ticket already used")).message
            == "The other device refused to pair: ticket already used")
        #expect(DevicesProblem.map(APIError(status: 500, code: "internal", message: "boom")) == .failed("boom"))
    }

    @Test func loadFillsOwnIdentityAndDevices() async {
        let api = FakeDevicesAPI()
        api.list.devices = [DeviceInfo(deviceId: "bbbb2222", name: "Phone")]
        let vm = make(api)
        await vm.load()
        #expect(vm.availability == .ready && vm.ownName == "My Mac" && vm.ownId == "aaaa1111")
        #expect(vm.devices.count == 1 && vm.canSync)
    }

    @Test func loadOfflineAndSyncDisabled() async {
        let api = FakeDevicesAPI()
        api.error = ConnectionError.unreachable("nope")
        let vm = make(api)
        await vm.load()
        #expect(vm.availability == .offline("nope"))
        api.error = APIError(status: 501, code: "sync_disabled", message: "off")
        await vm.load()
        #expect(vm.availability == .syncDisabled)
        api.error = nil
        await vm.load()
        #expect(vm.availability == .ready)
    }

    @Test func offerCountdownRoundsUpAndNeverNegative() async {
        let api = FakeDevicesAPI()
        let clock = MutableClock(1_000_000)
        api.offers = [PairOffer(ticket: "T", expiresMs: 1_000_000 + 300_000)]
        let vm = make(api, clock: clock)
        await vm.beginOfferSession()
        #expect(vm.offer?.remainingSeconds == 300 && vm.offer?.countdownText == "5:00")
        clock.now += 61_500
        await vm.tick()
        #expect(vm.offer?.remainingSeconds == 239 && vm.offer?.countdownText == "3:59")
        vm.endOfferSession()
        #expect(vm.offer == nil)
    }

    @Test func expiredOfferIsReplacedAutomatically() async {
        let api = FakeDevicesAPI()
        let clock = MutableClock(1_000_000)
        api.offers = [
            PairOffer(ticket: "first", expiresMs: 1_000_000 + 300_000),
            PairOffer(ticket: "second", expiresMs: 1_000_000 + 600_000),
        ]
        let vm = make(api, clock: clock)
        await vm.beginOfferSession()
        #expect(vm.offer?.offer.ticket == "first")
        clock.now += 299_000
        await vm.tick()
        #expect(vm.offer?.offer.ticket == "first")
        clock.now += 1_000
        await vm.tick()
        #expect(vm.offer?.offer.ticket == "second" && vm.offer?.remainingSeconds == 300)
        #expect(api.offerCalls == 2)
        vm.endOfferSession()
    }

    @Test func tickDoesNothingOutsideASession() async {
        let api = FakeDevicesAPI()
        let vm = make(api)
        await vm.tick()
        #expect(api.offerCalls == 0 && vm.offer == nil)
    }

    @Test func offerFailureStatesAreMapped() async {
        let api = FakeDevicesAPI()
        api.error = APIError(status: 501, code: "sync_disabled", message: "off")
        let vm = make(api)
        await vm.beginOfferSession()
        #expect(vm.offer == nil && vm.availability == .syncDisabled)
        api.error = APIError(status: 500, code: "internal", message: "boom")
        await vm.newOffer()
        #expect(vm.offerError == "boom")
        vm.endOfferSession()
    }

    @Test func spentOfferIsDroppedWhenAPeerAppears() async {
        let api = FakeDevicesAPI()
        api.offers = [PairOffer(ticket: "T", expiresMs: 1_000_000 + 300_000)]
        let vm = make(api)
        await vm.beginOfferSession()
        api.list.devices = [DeviceInfo(deviceId: "bb", name: "Phone")]
        for _ in 0..<DevicesViewModel.pollEvery { await vm.tick() }
        #expect(vm.offer == nil && vm.pairedNotice == "Paired with Phone.")
        #expect(vm.devices.count == 1)
        vm.endOfferSession()
    }

    @Test func joinPairsReloadsAndClearsTicket() async {
        let api = FakeDevicesAPI()
        let vm = make(api)
        vm.joinTicket = "  pomo-pair:x \n"
        #expect(vm.canJoin)
        await vm.join()
        #expect(vm.joinMessage == "Paired with Other." && !vm.joinFailed && vm.joinTicket.isEmpty)
        #expect(vm.devices.map(\.name) == ["Other"])
        vm.joinTicket = "  "
        #expect(!vm.canJoin)
    }

    @Test func joinErrorsKeepTicketAndExplain() async {
        let api = FakeDevicesAPI()
        api.error = APIError(status: 400, code: "bad_ticket", message: "x")
        let vm = make(api)
        vm.joinTicket = "junk"
        await vm.join()
        #expect(vm.joinFailed && vm.joinTicket == "junk" && vm.joinMessage?.contains("not valid") == true)
        #expect(vm.availability == .loading)
    }

    @Test func syncNowReportsPerPeerResults() async {
        let api = FakeDevicesAPI()
        api.list.devices = [DeviceInfo(deviceId: "bbbbbbbbbb", name: "Phone")]
        api.syncResult = [PeerSync(deviceId: "bbbbbbbbbb", sent: 2, received: 5), PeerSync(deviceId: "zzzzzzzzzzzz", error: "unreachable")]
        let vm = make(api)
        await vm.load()
        await vm.syncNow()
        #expect(vm.syncResults == api.syncResult && !vm.isSyncing)
        #expect(vm.name(for: "bbbbbbbbbb") == "Phone" && vm.name(for: "zzzzzzzzzzzz") == "zzzzzzzz")
        api.error = APIError(status: 501, code: "sync_disabled", message: "off")
        await vm.syncNow()
        #expect(vm.syncResults == nil && vm.availability == .syncDisabled)
    }

    @Test func revokeMarksDeviceAndExcludesItFromSync() async {
        let api = FakeDevicesAPI()
        api.list.devices = [DeviceInfo(deviceId: "bb", name: "Phone")]
        let vm = make(api)
        await vm.load()
        await vm.revoke(vm.devices[0])
        #expect(vm.devices[0].revoked && vm.activeDevices.isEmpty && !vm.canSync)
    }
}

@Suite struct QRCodeTests {
    @Test func rendersCrispAndRoundTrips() throws {
        let ticket = "pomo-pair:" + String(repeating: "abcdef0123456789", count: 8)
        let r = try #require(QRCode.render(ticket, maxPixels: 400))
        #expect(r.image.width == r.image.height && r.image.width == r.modules * r.scale)
        #expect(r.scale >= 2)
        #expect(QRCode.decode(r.image) == ticket)
    }
}
