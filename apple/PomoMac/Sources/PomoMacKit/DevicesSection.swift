import AppKit
import PomoUI
import SwiftUI

/// Settings > Devices: identity, paired Devices, pairing both ways, sync and revoke.
public struct DevicesSection: View {
    var model: DevicesViewModel
    @State private var pairing = false
    @State private var revoking: DeviceInfo?
    @State private var copiedId = false
    @State private var copiedTicket = false
    @Environment(\.pomoTheme) private var theme

    public init(model: DevicesViewModel, pairing: Bool = false) {
        self.model = model
        _pairing = State(initialValue: pairing)
    }

    public var body: some View {
        Section("Devices") {
            switch model.availability {
            case .loading:
                Text("Loading…").foregroundStyle(theme.inkMuted)
            case let .offline(message):
                notice("The daemon is not running", message, symbol: "exclamationmark.triangle")
                Button("Try again") { Task { await model.load() } }
            case .syncDisabled:
                notice("Sync is turned off", "The daemon was started with --sync off. Restart it without that flag to pair devices.", symbol: "icloud.slash")
            case .ready:
                ready
            }
        }
        .listRowBackground(theme.paperRaised)
        .task { await model.load() }
        .confirmationDialog(
            "Revoke \(revoking?.name ?? "device")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { device in
            Button("Revoke \(device.name)", role: .destructive) { Task { await model.revoke(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will stop receiving your events. Pair it again to bring it back.")
        }
        .onChange(of: pairing) { _, on in
            Task { if on { await model.beginOfferSession() } else { model.endOfferSession() } }
        }
        .onChange(of: model.availability) { _, a in if a != .ready { pairing = false } }
        .onChange(of: model.pairedNotice) { _, n in if n != nil { pairing = false } }
        .onAppear { if pairing { Task { await model.beginOfferSession() } } }
        .onDisappear { model.endOfferSession() }
    }

    // MARK: Ready

    @ViewBuilder private var ready: some View {
        LabeledContent("This device") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.ownName).fontWeight(.medium)
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(shortId(model.ownId))
                        .font(.system(size: Tokens.TypeSize.secondary, design: .monospaced))
                        .foregroundStyle(theme.inkMuted)
                        .textSelection(.enabled)
                        .help(model.ownId)
                    Button {
                        copy(model.ownId)
                        copiedId = true
                    } label: { Image(systemName: copiedId ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy device id")
                        .accessibilityLabel("Copy device id")
                }
            }
        }
        .onChange(of: model.ownId) { _, _ in copiedId = false }

        if model.devices.isEmpty {
            Text("No paired devices yet.").foregroundStyle(theme.inkMuted)
        } else {
            ForEach(model.devices) { device in row(device) }
        }
        if let e = model.actionError { Text(e).pomoFont(.secondary).foregroundStyle(theme.danger) }

        syncRow
        pairPanel
        joinRow
    }

    private func row(_ d: DeviceInfo) -> some View {
        HStack {
            Image(systemName: d.revoked ? "iphone.slash" : "iphone")
                .foregroundStyle(d.revoked ? theme.inkMuted : theme.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).strikethrough(d.revoked).foregroundStyle(d.revoked ? theme.inkMuted : theme.ink)
                Text(shortId(d.deviceId))
                    .font(.system(size: Tokens.TypeSize.secondary, design: .monospaced))
                    .foregroundStyle(theme.inkMuted)
                    .help(d.deviceId)
            }
            Spacer()
            if d.revoked {
                Text("Revoked")
                    .pomoFont(.secondary, weight: .medium)
                    .foregroundStyle(theme.danger)
            } else {
                Button("Revoke…", role: .destructive) { revoking = d }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Revoke \(d.name)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.name)\(d.revoked ? ", revoked" : "")")
    }

    private var syncRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Button { Task { await model.syncNow() } } label: {
                    if model.isSyncing {
                        HStack(spacing: Tokens.Spacing.s) { ProgressView().controlSize(.small); Text("Syncing…") }
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!model.canSync)
                if model.activeDevices.isEmpty {
                    Text(model.devices.isEmpty ? "Pair a device first." : "Every paired device is revoked.").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
                }
            }
            if let e = model.syncError { Text(e).pomoFont(.secondary).foregroundStyle(theme.danger) }
            if let results = model.syncResults {
                if results.isEmpty {
                    Text("No device is reachable from here yet. Sync from the other device, or pair again from this side.").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
                }
                ForEach(results) { r in
                    HStack(spacing: Tokens.Spacing.xs) {
                        Image(systemName: r.error == nil ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(r.error == nil ? theme.ink : theme.danger)
                            .accessibilityHidden(true)
                        if let error = r.error {
                            Text("\(model.name(for: r.deviceId)): \(error)").foregroundStyle(theme.danger)
                        } else {
                            Text("\(model.name(for: r.deviceId)): sent \(r.sent ?? 0), received \(r.received ?? 0)")
                        }
                    }
                    .pomoFont(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Pairing

    @ViewBuilder private var pairPanel: some View {
        if let notice = model.pairedNotice {
            Label(notice, systemImage: "checkmark.circle").foregroundStyle(theme.ink)
        }
        if pairing {
            VStack(spacing: Tokens.Spacing.m) {
                if let state = model.offer {
                    QRView(ticket: state.offer.ticket, size: 220)
                        .padding(Tokens.Spacing.l)
                        .background(theme.paperRaised, in: RoundedRectangle(cornerRadius: Tokens.Radius.surface))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.surface).stroke(theme.hairline))
                    HStack(spacing: Tokens.Spacing.m) {
                        Text("Expires in \(state.countdownText)")
                            .monospacedDigit()
                            .foregroundStyle(state.remainingSeconds <= 30 ? theme.danger : theme.inkMuted)
                            .accessibilityLabel("Ticket expires in \(state.remainingSeconds) seconds")
                        Button {
                            copy(state.offer.ticket)
                            copiedTicket = true
                        } label: { Label(copiedTicket ? "Copied" : "Copy ticket", systemImage: copiedTicket ? "checkmark" : "doc.on.doc") }
                    }
                    Text("Scan on the other device, or paste the ticket there. It works once. A new one appears when this expires.")
                        .pomoFont(.secondary).foregroundStyle(theme.inkMuted).multilineTextAlignment(.center)
                } else if model.isOffering {
                    ProgressView("Getting a ticket…")
                } else if let e = model.offerError {
                    Text(e).foregroundStyle(theme.danger)
                    Button("Try again") { Task { await model.newOffer() } }
                }
                Button("Done") { pairing = false }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.Spacing.s)
            .onChange(of: model.offer?.offer.ticket) { _, _ in copiedTicket = false }
        } else {
            Button { pairing = true } label: { Label("Pair a new device", systemImage: "qrcode") }
        }
    }

    private var joinRow: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack {
                TextField("Join with ticket", text: $m.joinTicket, prompt: Text("Paste a pomo-pair: ticket"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.join() } }
                    .accessibilityLabel("Ticket from the other device")
                Button("Join") { Task { await model.join() } }
                    .disabled(!model.canJoin)
            }
            if model.isJoining { ProgressView().controlSize(.small) }
            if let message = model.joinMessage {
                Text(message).pomoFont(.secondary).foregroundStyle(model.joinFailed ? theme.danger : theme.ink)
            }
        }
    }

    // MARK: Helpers

    private func notice(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: symbol).foregroundStyle(theme.inkMuted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).pomoFont(.secondary).foregroundStyle(theme.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func shortId(_ id: String) -> String { id.count > 12 ? "\(id.prefix(8))…\(id.suffix(4))" : id }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A QR code drawn with integer module scaling and no interpolation.
struct QRView: View {
    var ticket: String
    var size: CGFloat
    @Environment(\.pomoTheme) private var theme

    var body: some View {
        if let qr = QRCode.render(ticket, maxPixels: Int(size * 2)) {
            Image(decorative: qr.image, scale: 2)
                .interpolation(.none)
                .resizable()
                .frame(width: CGFloat(qr.image.width) / 2, height: CGFloat(qr.image.height) / 2)
                .accessibilityElement()
                .accessibilityLabel("Pairing QR code")
                .accessibilityHint("Scan with the other device, or copy the ticket instead")
        } else {
            Text("Could not draw the QR code. Copy the ticket instead.").foregroundStyle(theme.inkMuted)
        }
    }
}
