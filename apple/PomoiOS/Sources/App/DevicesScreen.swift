import PomoKit
import PomoUI
import SwiftUI

struct DevicesScreen: View {
    var devices: DevicesViewModel
    var sync: SyncCoordinator
    @Environment(\.pomoTheme) private var theme
    @State private var scanning = false
    @State private var confirmRevoke: DeviceInfo?
    @FocusState private var ticketFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                thisDevice
                pairedDevices
                pairing
                syncSection
            }
            .scrollContentBackground(.hidden)
            .background(theme.paper)
            .navigationTitle("Devices")
            .task { await devices.load() }
            .refreshable { await devices.load() }
            .sheet(isPresented: $scanning) { ScannerSheet(devices: devices, isPresented: $scanning) }
            .confirmationDialog(
                "Revoke \(confirmRevoke?.name ?? "device")?", isPresented: Binding(
                    get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }
                ), titleVisibility: .visible
            ) {
                Button("Revoke", role: .destructive) {
                    if let d = confirmRevoke { Task { await devices.revoke(d) } }
                    confirmRevoke = nil
                }
            } message: {
                Text("It stops receiving your events. Pair it again to restore it.")
            }
        }
    }

    private var thisDevice: some View {
        Section("This device") {
            LabeledContent("Name", value: devices.ownName.isEmpty ? "–" : devices.ownName)
            LabeledContent("ID", value: String(devices.ownId.prefix(12)))
                .font(.system(size: Tokens.TypeSize.secondary, design: .monospaced))
        }
        .listRowBackground(theme.paperRaised)
    }

    private var pairedDevices: some View {
        Section("Paired devices") {
            if devices.devices.isEmpty {
                Text("None yet. Scan the QR code shown on your Mac, or paste its ticket below.")
                    .font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.inkMuted)
            }
            ForEach(devices.devices) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name.isEmpty ? String(d.deviceId.prefix(8)) : d.name)
                        Text(d.revoked ? "Revoked" : (d.paired ? "Paired" : "Not paired"))
                            .font(.system(size: Tokens.TypeSize.secondary))
                            .foregroundStyle(d.revoked ? theme.danger : theme.inkMuted)
                    }
                    Spacer()
                    if !d.revoked {
                        Button("Revoke", role: .destructive) { confirmRevoke = d }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Revoke \(d.name)")
                    }
                }
            }
            if let e = devices.actionError {
                Text(e).foregroundStyle(theme.danger).font(.system(size: Tokens.TypeSize.secondary))
            }
        }
        .listRowBackground(theme.paperRaised)
    }

    private var pairing: some View {
        Section {
            Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                .frame(minHeight: 44)
            TextField("Or paste a pairing ticket", text: Bindable(devices).joinTicket, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: Tokens.TypeSize.secondary, design: .monospaced))
                .accessibilityIdentifier("devices.ticket")
                .focused($ticketFocused)
            if !devices.joinTicket.isEmpty {
                Button { ticketFocused = false; Task { await devices.join() } } label: {
                    if devices.isJoining { ProgressView() } else { Text("Pair") }
                }
                .disabled(!devices.canJoin)
                .frame(minHeight: 44)
                .accessibilityIdentifier("devices.pair")
            }
            if let m = devices.joinMessage {
                Text(m).font(.system(size: Tokens.TypeSize.secondary))
                    .foregroundStyle(devices.joinFailed ? theme.danger : theme.ink)
                    .accessibilityIdentifier("devices.joinMessage")
            }
        } header: {
            Text("Pair another device")
        } footer: {
            Text("On your Mac run `pomo pair offer`, or open Settings in the Pomo menu bar app, and scan the code. The ticket works once and expires after five minutes.")
        }
        .listRowBackground(theme.paperRaised)
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await sync.syncNow(); await devices.load() }
            } label: {
                HStack {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if sync.isSyncing { ProgressView() }
                }
            }
            .disabled(sync.isSyncing)
            .frame(minHeight: 44)
            ForEach(sync.lastResults) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(devices.name(for: r.deviceId))
                    if let e = r.error {
                        Text(e).foregroundStyle(theme.danger)
                    } else {
                        Text("Sent \(r.sent ?? 0), received \(r.received ?? 0)").foregroundStyle(theme.inkMuted)
                    }
                }
                .font(.system(size: Tokens.TypeSize.secondary))
            }
            if let e = sync.lastError, sync.lastResults.isEmpty {
                Text(e).foregroundStyle(theme.danger).font(.system(size: Tokens.TypeSize.secondary))
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(syncFooter)
        }
        .listRowBackground(theme.paperRaised)
    }

    private var syncFooter: String {
        let base = "Sync runs when the app opens and every minute while it is open."
        guard let ms = sync.lastSyncMs else { return base }
        return base + " Last: " + Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .standard) + "."
    }
}

/// The scanner in a sheet. A recognised ticket pairs and closes the sheet; any other code is ignored.
private struct ScannerSheet: View {
    var devices: DevicesViewModel
    @Binding var isPresented: Bool
    @State private var gate = ScanGate()
    @State private var status = "Point the camera at the QR code on your Mac."

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRScannerView { payload in
                    guard let ticket = gate.accept(payload, now: Date()) else { return }
                    status = "Pairing…"
                    Task {
                        devices.joinTicket = ticket
                        await devices.join()
                        if devices.joinFailed {
                            status = devices.joinMessage ?? "Pairing failed."
                        } else {
                            isPresented = false
                        }
                    }
                }
                .ignoresSafeArea()
                Text(status)
                    .padding(Tokens.Spacing.m)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.surface))
                    .padding(Tokens.Spacing.l)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .navigationTitle("Scan to pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } } }
            // The preview is black or a camera feed: keep the status pill and Cancel legible in either appearance.
            .preferredColorScheme(.dark)
            .foregroundStyle(.white)
            .tint(.white)
        }
    }
}
