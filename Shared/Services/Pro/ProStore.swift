import Foundation
import StoreKit

/// Lelvo Pro entitlement. Purchases go through the App Store / Mac App Store (StoreKit 2). No Lelvo account server.
/// Product IDs must match App Store Connect (and the local StoreKit config in Debug).
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    static let yearlyId = "app.lelvo.pro.yearly"
    static let monthlyId = "app.lelvo.pro.monthly"
    static let lifetimeId = "app.lelvo.pro.lifetime"
    static let productIds: Set<String> = [yearlyId, monthlyId, lifetimeId]

    /// Off for 1.0: Pro isn't finished, so no Pro screen, badge, upsell or store call is shown. The code stays; flip
    /// this to bring it back, and put `NSFaceIDUsageDescription` back in project.yml first (Locked Folder uses Face ID;
    /// without the key iOS ends the app on the first Face ID call). Free features never depend on it.
    static let offered = false

    @Published private(set) var isPro = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published var errorMessage: String?

    /// Debug / TestFlight: unlock without a store purchase. Cleared when a real entitlement arrives.
    @Published var debugUnlocked: Bool {
        didSet { Prefs.defaults.set(debugUnlocked, forKey: Prefs.Key.proDebugUnlocked); refreshEntitlement() }
    }

    private var updates: Task<Void, Never>?

    private init() {
        debugUnlocked = Prefs.defaults.bool(forKey: Prefs.Key.proDebugUnlocked)
        refreshEntitlement()
        guard Self.offered else { return }
        updates = Task { await listenForTransactions() }
        Task { await loadProducts() }
    }

    deinit { updates?.cancel() }

    var yearly: Product? { products.first { $0.id == Self.yearlyId } }
    var monthly: Product? { products.first { $0.id == Self.monthlyId } }
    var lifetime: Product? { products.first { $0.id == Self.lifetimeId } }

    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIds).sorted { $0.price < $1.price }
        } catch {
            AppLog.shared.warn("Pro: couldn't load products (\(error.localizedDescription))")
        }
    }

    func purchase(_ product: Product) async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try check(verification)
                await transaction.finish()
                await updateEntitlement()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Couldn't complete the purchase. Try again."
            AppLog.shared.warn("Pro: purchase failed (\(error.localizedDescription))")
        }
    }

    func restore() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            // Awaited: read before it finished, isPro was still false and a real purchase showed as "not found".
            await updateEntitlement()
            if !isPro { errorMessage = "No Pro purchase found for this Apple ID." }
        } catch {
            errorMessage = "Couldn't restore purchases. Try again."
            AppLog.shared.warn("Pro: restore failed (\(error.localizedDescription))")
        }
    }

    func refreshEntitlement() {
        Task { await updateEntitlement() }
    }

    func updateEntitlement() async {
        var entitled = debugUnlocked
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, Self.productIds.contains(t.productID) else { continue }
            if t.revocationDate != nil { continue }
            entitled = true
            break
        }
        isPro = entitled
    }

    private func listenForTransactions() async {
        for await update in Transaction.updates {
            if case .verified(let t) = update {
                await t.finish()
                await updateEntitlement()
            }
        }
    }

    private func check(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let t): return t
        }
    }
}
