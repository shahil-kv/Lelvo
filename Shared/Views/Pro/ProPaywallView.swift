import SwiftUI
import StoreKit

/// Shown when a Pro feature is tapped without an entitlement. StoreKit handles payment and offer-code redemption.
struct ProPaywallView: View {
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRedeem = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lelvo Pro")
                            .font(.largeTitle.bold())
                        Text("Smart search, Locked folder, cleanup and more — on top of free backup and restore.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        feature("lock.fill", "Locked folder", "Hide photos behind Face ID or your passcode", pro: true)
                        feature("sparkle.magnifyingglass", "Smart search", "Find by what’s in a photo — text, things and scenes", pro: true)
                        feature("wand.and.stars", "Smart cleanup", "Similar shots, screenshots, large videos and more", pro: true)
                        feature("sparkles", "Memories themes", "Pets, beaches, food and other theme stories", pro: true)
                        #if os(macOS)
                        feature("externaldrive.badge.checkmark", "Folder backup", "Keep a second copy on a drive you own", pro: true)
                        #endif
                    }

                    if let err = pro.errorMessage {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }

                    VStack(spacing: 12) {
                        if let yearly = pro.yearly {
                            Button {
                                Task { await pro.purchase(yearly); if pro.isPro { dismiss() } }
                            } label: {
                                Text(pro.busy ? "Working…" : "Try free, then \(yearly.displayPrice)/year")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pro.busy)
                        } else {
                            Button("Loading prices…") {}
                                .buttonStyle(.borderedProminent)
                                .disabled(true)
                                .frame(maxWidth: .infinity)
                        }
                        if let monthly = pro.monthly {
                            Button {
                                Task { await pro.purchase(monthly); if pro.isPro { dismiss() } }
                            } label: {
                                Text("\(monthly.displayPrice)/month")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(pro.busy)
                        }
                        if let life = pro.lifetime {
                            Button {
                                Task { await pro.purchase(life); if pro.isPro { dismiss() } }
                            } label: {
                                Text("Lifetime · \(life.displayPrice)")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(pro.busy)
                        }
                    }

                    VStack(spacing: 8) {
                        Button("Restore purchases") { Task { await pro.restore(); if pro.isPro { dismiss() } } }
                            .disabled(pro.busy)
                        Button("Redeem code") { showRedeem = true }
                        #if DEBUG
                        Toggle("Debug: unlock Pro", isOn: $pro.debugUnlocked)
                            .onChange(of: pro.debugUnlocked) { _, on in if on { dismiss() } }
                        #endif
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)

                    Text("Backup, restore, encryption and Free Up Space stay free. Cancel anytime in Settings → Apple ID → Subscriptions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .cancel) { dismiss() }
                }
            }
            #if os(iOS)
            .offerCodeRedemption(isPresented: $showRedeem) { _ in
                pro.refreshEntitlement()
                if pro.isPro { dismiss() }
            }
            #endif
            .task { await pro.loadProducts() }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ subtitle: String, pro: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if pro { ProBadge() }
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
