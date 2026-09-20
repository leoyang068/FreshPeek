import Foundation
import Combine

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var items: [FoodItem] = []
    @Published private(set) var removedRecords: [RemovedFoodRecord] = []
    @Published private(set) var shelfLifeRules: [ShelfLifeRule] = []
    @Published var thresholdDays: Int {
        didSet {
            let clampedValue = min(max(thresholdDays, 1), 14)
            guard thresholdDays == clampedValue else {
                thresholdDays = clampedValue
                return
            }
            UserDefaults.standard.set(thresholdDays, forKey: Keys.thresholdDays)
            refreshRemindersIfNeeded()
            queueSettingsSync()
        }
    }
    @Published var cuisine: Cuisine {
        didSet {
            UserDefaults.standard.set(cuisine.rawValue, forKey: Keys.cuisine)
            queueSettingsSync()
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            refreshRemindersIfNeeded()
            queueSettingsSync()
        }
    }
    @Published private(set) var lastSyncDate: Date
    @Published private(set) var syncError: String?

    private var isApplyingRemoteSettings = false
    private var pollingTask: Task<Void, Never>?

    private enum Keys {
        static let items = "inventory.items.v1"
        static let removed = "inventory.removed.v1"
        static let shelfLifeRules = "inventory.shelf-life-rules.v1"
        static let thresholdDays = "settings.threshold-days.v1"
        static let cuisine = "settings.cuisine.v1"
        static let notificationsEnabled = "settings.notifications-enabled.v1"
        static let lastSyncDate = "inventory.last-sync.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        let savedThreshold = defaults.object(forKey: Keys.thresholdDays) as? Int
        thresholdDays = savedThreshold ?? 3
        cuisine = Cuisine.fromStoredValue(defaults.string(forKey: Keys.cuisine) ?? "") ?? .chinese
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        lastSyncDate = defaults.object(forKey: Keys.lastSyncDate) as? Date ?? .now
        syncError = nil

        items = Self.decode([FoodItem].self, from: defaults.data(forKey: Keys.items))
            ?? []
        removedRecords = Self.decode([RemovedFoodRecord].self, from: defaults.data(forKey: Keys.removed))
            ?? []
        shelfLifeRules = Self.decode([ShelfLifeRule].self, from: defaults.data(forKey: Keys.shelfLifeRules))
            ?? Self.seedShelfLifeRules
    }

    var sortedItems: [FoodItem] {
        items.sorted {
            if $0.expiryDate != $1.expiryDate { return $0.expiryDate < $1.expiryDate }
            return $0.lastUpdatedAt > $1.lastUpdatedAt
        }
    }

    func update(_ item: FoodItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var edited = item
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.canonicalName = edited.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.shelfLifeDays = max(1, edited.shelfLifeDays)
        edited.lastUpdatedAt = .now
        items[index] = edited
        persistInventory(syncDate: false)
        Task { await updateCloudItem(edited) }
    }

    func manuallyDelete(_ item: FoodItem) {
        remove(item, reason: .manual)
    }

    @discardableResult
    func removeOutgoing(canonicalName: String) -> FoodItem? {
        let normalized = normalize(canonicalName)
        guard let item = items
            .filter({ normalize($0.canonicalName) == normalized })
            .min(by: { $0.expiryDate < $1.expiryDate }) else {
            return nil
        }
        remove(item, reason: .automaticOut)
        return item
    }

    func restoreMostRecentManualDeletion() {
        guard let record = removedRecords
            .filter({ $0.reason == .manual })
            .max(by: { $0.removedAt < $1.removedAt }) else { return }
        restore(record)
    }

    /// Gesture return rule: keep an existing same-name item unchanged. If no item exists,
    /// restore today's most recent automatic-out record with the same canonical name.
    @discardableResult
    func processReturn(canonicalName: String, now: Date = .now) -> FoodItem? {
        let normalized = normalize(canonicalName)
        if let existing = items.first(where: { normalize($0.canonicalName) == normalized }) {
            return existing
        }

        let calendar = Calendar.current
        guard let record = removedRecords
            .filter({
                $0.reason == .automaticOut
                    && normalize($0.item.canonicalName) == normalized
                    && calendar.isDate($0.removedAt, inSameDayAs: now)
            })
            .max(by: { $0.removedAt < $1.removedAt }) else {
            return nil
        }

        restore(record)
        return record.item
    }

    /// V1 incoming rule: merge into an existing green item and keep the earlier expiry.
    /// Orange/red batches remain separate so the older item stays visible at the top.
    func mergeIncoming(_ incoming: FoodItem) {
        let normalized = normalize(incoming.canonicalName)
        if let index = items.firstIndex(where: {
            normalize($0.canonicalName) == normalized
                && $0.expiryState(thresholdDays: thresholdDays) == .fresh
        }) {
            if incoming.expiryDate < items[index].expiryDate {
                items[index].addedDate = incoming.addedDate
                items[index].shelfLifeDays = incoming.shelfLifeDays
            }
            items[index].lastUpdatedAt = .now
            let merged = items[index]
            Task { await updateCloudItem(merged) }
        } else {
            items.append(incoming)
            Task { await insertCloudItem(incoming, userCorrected: false) }
        }
        markSynced()
        persistInventory(syncDate: true)
    }

    func add(_ item: FoodItem) {
        items.append(item)
        markSynced()
        persistInventory(syncDate: true)
        Task { await insertCloudItem(item, userCorrected: true) }
    }

    func connectToCloud() async {
        await refreshFromCloud()
        startPolling()
    }

    func refreshFromCloud() async {
        syncError = nil

        do {
            let cloud = try await SingleUserCloudAPI.bootstrap()

            items = cloud.inventoryItems
                .filter { $0.deletedAt == nil }
                .map(\.foodItem)

            if !cloud.shelfLifeRules.isEmpty {
                shelfLifeRules = cloud.shelfLifeRules.map(\.rule)
            }

            if let settings = cloud.settings {
                isApplyingRemoteSettings = true
                thresholdDays = settings.expiringThresholdDays
                cuisine = Cuisine.fromStoredValue(settings.cuisine) ?? .chinese
                notificationsEnabled = settings.notificationsEnabled
                isApplyingRemoteSettings = false
            } else {
                await syncSettings()
            }

            persistInventory(syncDate: true)
            syncError = nil
        } catch {
            syncError = "Unable to connect to the cloud"
        }
    }

    func suggestedShelfLife(for foodName: String) -> Int? {
        let normalized = normalize(foodName)
        guard !normalized.isEmpty else { return nil }
        return shelfLifeRules.first(where: {
            normalize($0.canonicalName) == normalized
        })?.shelfLifeDays
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    func markSynced(at date: Date = .now) {
        lastSyncDate = date
        UserDefaults.standard.set(date, forKey: Keys.lastSyncDate)
    }

    private func remove(_ item: FoodItem, reason: RemovalReason) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        removedRecords.append(RemovedFoodRecord(item: removed, reason: reason))
        persistInventory(syncDate: false)
        Task { await setCloudDeletion(for: removed.id, deleted: true) }
    }

    private func restore(_ record: RemovedFoodRecord) {
        guard !items.contains(where: { $0.id == record.item.id }) else { return }
        items.append(record.item)
        removedRecords.removeAll(where: { $0.id == record.id })
        persistInventory(syncDate: false)
        Task { await setCloudDeletion(for: record.item.id, deleted: false) }
    }

    private func insertCloudItem(_ item: FoodItem, userCorrected: Bool) async {
        let now = Date.now
        let payload = InventoryInsert(
            id: item.id,
            food_name: item.name,
            canonical_name: item.canonicalName,
            added_at: SupabaseDate.timestamp(item.addedDate),
            last_added_at: SupabaseDate.timestamp(item.lastUpdatedAt),
            shelf_life_days: item.shelfLifeDays,
            expiry_date: SupabaseDate.dateOnly(item.expiryDate),
            user_corrected: userCorrected,
            updated_at: SupabaseDate.timestamp(now)
        )

        do {
            try await SingleUserCloudAPI.insert(payload)
            markSynced()
            syncError = nil
        } catch {
            syncError = "New food has not synced yet"
        }
    }

    private func updateCloudItem(_ item: FoodItem) async {
        let payload = InventoryUpdate(
            food_name: item.name,
            canonical_name: item.canonicalName,
            added_at: SupabaseDate.timestamp(item.addedDate),
            last_added_at: SupabaseDate.timestamp(item.lastUpdatedAt),
            shelf_life_days: item.shelfLifeDays,
            expiry_date: SupabaseDate.dateOnly(item.expiryDate),
            user_corrected: true,
            updated_at: SupabaseDate.timestamp(.now)
        )

        do {
            try await SingleUserCloudAPI.update(id: item.id, item: payload)
            markSynced()
            syncError = nil
        } catch {
            syncError = "Food changes have not synced yet"
        }
    }

    private func setCloudDeletion(for id: UUID, deleted: Bool) async {
        let now = Date.now

        do {
            try await SingleUserCloudAPI.setDeleted(
                id: id,
                deletedAt: deleted ? SupabaseDate.timestamp(now) : nil,
                updatedAt: SupabaseDate.timestamp(now)
            )
            markSynced()
            syncError = nil
        } catch {
            syncError = deleted ? "Delete has not synced yet" : "Restore has not synced yet"
        }
    }

    private func queueSettingsSync() {
        guard !isApplyingRemoteSettings else { return }
        Task { await syncSettings() }
    }

    private func syncSettings() async {
        let payload = UserSettingsUpsert(
            expiring_threshold_days: thresholdDays,
            cuisine: cuisine.rawValue,
            notifications_enabled: notificationsEnabled,
            updated_at: SupabaseDate.timestamp(.now)
        )

        do {
            try await SingleUserCloudAPI.upsertSettings(payload)
            syncError = nil
        } catch {
            syncError = "Settings have not synced yet"
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await self?.refreshFromCloud()
            }
        }
    }

    private func persistInventory(syncDate: Bool) {
        let encoder = JSONEncoder()
        UserDefaults.standard.set(try? encoder.encode(items), forKey: Keys.items)
        UserDefaults.standard.set(try? encoder.encode(removedRecords), forKey: Keys.removed)
        UserDefaults.standard.set(try? encoder.encode(shelfLifeRules), forKey: Keys.shelfLifeRules)
        if syncDate { markSynced() }
        refreshRemindersIfNeeded()
    }

    private func refreshRemindersIfNeeded() {
        guard notificationsEnabled else {
            Task { await NotificationManager.shared.clearExpiryReminders() }
            return
        }
        let currentItems = items
        let threshold = thresholdDays
        Task {
            await NotificationManager.shared.scheduleExpiryReminders(
                for: currentItems,
                thresholdDays: threshold
            )
        }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static var seedShelfLifeRules: [ShelfLifeRule] {
        [
            ShelfLifeRule(canonicalName: "leftovers", shelfLifeDays: 1, source: "system"),
            ShelfLifeRule(canonicalName: "spinach", shelfLifeDays: 3, source: "system"),
            ShelfLifeRule(canonicalName: "milk", shelfLifeDays: 7, source: "system"),
            ShelfLifeRule(canonicalName: "potato", shelfLifeDays: 14, source: "system")
        ]
    }
}
