import Foundation
import Testing
import PomoCoreFFI
import PomoUI
@testable import PomoKit

struct PairingAndSyncTests {
    @Test func twoCoresPairAndShareOneTimerAndHistory() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let mac = try await makeEngine("mac", in: dir)
        let phone = try await makeEngine("phone", in: dir)

        // The phone watches its own event stream, as the app does.
        let phoneEvents = Collector<String>()
        let reader = Task { for try await e in phone.api.stream() { if case let .message(m) = e { phoneEvents.add(m.event) } } }
        defer { reader.cancel() }

        let offer = try await mac.api.pairOffer()
        #expect(PairingTicket.parse(offer.ticket) == offer.ticket, "a real ticket passes the scanner's check")
        let paired = try await phone.api.pairJoin(ticket: offer.ticket, name: nil)
        #expect(paired.deviceId == mac.deviceId && paired.name == "mac" && paired.paired)
        let macSide = try await mac.api.devices()
        #expect(macSide.name == "mac" && macSide.devices.map(\.name) == ["phone"])

        // Started on the Mac, pulled by the phone.
        let started = try await mac.api.start(label: "shared")
        let report = try await phone.api.sync(deviceId: nil)
        #expect(report.count == 1 && report[0].error == nil && report[0].received == 1)
        let onPhone = try await phone.api.status().timer
        #expect(onPhone.status == .running && onPhone.block?.id == started.block?.id)
        #expect(onPhone.block?.deviceId == mac.deviceId && onPhone.block?.label == "shared")
        #expect(await eventually { phoneEvents.all.contains("pomo.event") }, "synced events reach the stream")

        // Paused on the phone, pulled back by the same round.
        _ = try await phone.api.send(.pause, source: nil)
        _ = try await phone.api.sync(deviceId: nil)
        #expect(try await mac.api.status().timer.status == .paused)
        let macBlocks = try await mac.api.blocks(fromMs: nil, toMs: nil, limit: nil)
        let phoneBlocks = try await phone.api.blocks(fromMs: nil, toMs: nil, limit: nil)
        #expect(macBlocks == phoneBlocks)
    }

    @Test func aRevokedDeviceIsListedAsSuchAndNotSynced() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let mac = try await makeEngine("mac", in: dir)
        let phone = try await makeEngine("phone", in: dir)
        _ = try await phone.api.pairJoin(ticket: try await mac.api.pairOffer().ticket, name: nil)
        let revoked = try await phone.api.revoke(deviceId: mac.deviceId)
        #expect(revoked.revoked && !revoked.paired)
        #expect(try await phone.api.sync(deviceId: nil).isEmpty)
        #expect(try await phone.api.devices().devices.first?.revoked == true)
    }

    @Test func aSingleUseTicketCannotBeJoinedTwice() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let mac = try await makeEngine("mac", in: dir)
        let phone = try await makeEngine("phone", in: dir)
        let ticket = try await mac.api.pairOffer().ticket
        _ = try await phone.api.pairJoin(ticket: ticket, name: nil)
        do {
            _ = try await phone.api.pairJoin(ticket: ticket, name: nil)
            Issue.record("second join must be rejected")
        } catch let e as APIError {
            #expect(e.code == "pairing_rejected" && e.message == "used")
        }
    }

    @MainActor @Test func theSharedDevicesViewModelPairsAndSyncsOnTheCore() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let mac = try await makeEngine("mac", in: dir)
        let phone = try await makeEngine("phone", in: dir)
        let vm = DevicesViewModel(connector: { phone.api })
        await vm.load()
        #expect(vm.availability == .ready && vm.ownName == "phone" && vm.devices.isEmpty)

        vm.joinTicket = try await mac.api.pairOffer().ticket
        await vm.join()
        #expect(vm.joinFailed == false && vm.joinMessage == "Paired with mac.")
        #expect(vm.devices.map(\.name) == ["mac"])

        _ = try await mac.api.start(label: "from mac")
        await vm.syncNow()
        #expect(vm.syncResults?.first?.received == 1)
        #expect(try await phone.api.status().timer.status == .running)

        await vm.revoke(vm.devices[0])
        #expect(vm.devices[0].revoked)
    }
}
