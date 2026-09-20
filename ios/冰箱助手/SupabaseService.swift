import Foundation
import Supabase
import Functions

enum SupabaseConfig {
    static let client = SupabaseClient(
        supabaseURL: URL(string: "https://YOUR_PROJECT_REF.supabase.co")!,
        supabaseKey: "sb_publishable_YOUR_KEY"
    )
}

struct InventoryRow: Decodable {
    let id: UUID
    let ownerID: UUID
    let foodName: String
    let canonicalName: String
    let addedAt: String
    let shelfLifeDays: Int
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID = "owner_id"
        case foodName = "food_name"
        case canonicalName = "canonical_name"
        case addedAt = "added_at"
        case shelfLifeDays = "shelf_life_days"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    var foodItem: FoodItem {
        FoodItem(
            id: id,
            name: foodName,
            canonicalName: canonicalName,
            addedDate: SupabaseDate.parseTimestamp(addedAt) ?? .now,
            shelfLifeDays: shelfLifeDays,
            lastUpdatedAt: SupabaseDate.parseTimestamp(updatedAt) ?? .now
        )
    }
}

struct InventoryInsert: Encodable {
    let id: UUID
    let food_name: String
    let canonical_name: String
    let added_at: String
    let last_added_at: String
    let shelf_life_days: Int
    let expiry_date: String
    let user_corrected: Bool
    let updated_at: String
}

struct InventoryUpdate: Encodable {
    let food_name: String
    let canonical_name: String
    let added_at: String
    let last_added_at: String
    let shelf_life_days: Int
    let expiry_date: String
    let user_corrected: Bool
    let updated_at: String
}

struct ShelfLifeRuleRow: Decodable {
    let id: UUID
    let canonicalName: String
    let shelfLifeDays: Int
    let assumption: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalName = "canonical_name"
        case shelfLifeDays = "shelf_life_days"
        case assumption
        case source
    }

    var rule: ShelfLifeRule {
        ShelfLifeRule(
            id: id,
            canonicalName: canonicalName,
            shelfLifeDays: shelfLifeDays,
            assumption: assumption,
            source: source
        )
    }
}

struct UserSettingsRow: Decodable {
    let expiringThresholdDays: Int
    let cuisine: String
    let notificationsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case expiringThresholdDays = "expiring_threshold_days"
        case cuisine
        case notificationsEnabled = "notifications_enabled"
    }
}

struct UserSettingsUpsert: Encodable {
    let expiring_threshold_days: Int
    let cuisine: String
    let notifications_enabled: Bool
    let updated_at: String
}

struct AppBootstrapResponse: Decodable {
    let inventoryItems: [InventoryRow]
    let shelfLifeRules: [ShelfLifeRuleRow]
    let settings: UserSettingsRow?

    enum CodingKeys: String, CodingKey {
        case inventoryItems = "inventory_items"
        case shelfLifeRules = "shelf_life_rules"
        case settings
    }
}

private struct BootstrapRequest: Encodable {
    let action = "bootstrap"
}

private struct InsertItemRequest: Encodable {
    let action = "insert_item"
    let item: InventoryInsert
}

private struct UpdateItemRequest: Encodable {
    let action = "update_item"
    let itemID: UUID
    let item: InventoryUpdate

    enum CodingKeys: String, CodingKey {
        case action
        case itemID = "item_id"
        case item
    }
}

private struct SetDeletedRequest: Encodable {
    let action = "set_deleted"
    let itemID: UUID
    let deletedAt: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case action
        case itemID = "item_id"
        case deletedAt = "deleted_at"
        case updatedAt = "updated_at"
    }
}

private struct UpsertSettingsRequest: Encodable {
    let action = "upsert_settings"
    let settings: UserSettingsUpsert
}

private struct AppMutationResponse: Decodable {
    let ok: Bool
}

enum SingleUserCloudAPI {
    private static let headers = ["x-fridge-app-token": AppSecrets.fridgeAppToken]

    static func bootstrap() async throws -> AppBootstrapResponse {
        try await SupabaseConfig.client.functions.invoke(
            "app-api",
            options: FunctionInvokeOptions(
                headers: headers,
                body: BootstrapRequest(),
                timeoutInterval: 30
            )
        )
    }

    static func insert(_ item: InventoryInsert) async throws {
        let _: AppMutationResponse = try await SupabaseConfig.client.functions.invoke(
            "app-api",
            options: FunctionInvokeOptions(
                headers: headers,
                body: InsertItemRequest(item: item),
                timeoutInterval: 30
            )
        )
    }

    static func update(id: UUID, item: InventoryUpdate) async throws {
        let _: AppMutationResponse = try await SupabaseConfig.client.functions.invoke(
            "app-api",
            options: FunctionInvokeOptions(
                headers: headers,
                body: UpdateItemRequest(itemID: id, item: item),
                timeoutInterval: 30
            )
        )
    }

    static func setDeleted(id: UUID, deletedAt: String?, updatedAt: String) async throws {
        let _: AppMutationResponse = try await SupabaseConfig.client.functions.invoke(
            "app-api",
            options: FunctionInvokeOptions(
                headers: headers,
                body: SetDeletedRequest(
                    itemID: id,
                    deletedAt: deletedAt,
                    updatedAt: updatedAt
                ),
                timeoutInterval: 30
            )
        )
    }

    static func upsertSettings(_ settings: UserSettingsUpsert) async throws {
        let _: AppMutationResponse = try await SupabaseConfig.client.functions.invoke(
            "app-api",
            options: FunctionInvokeOptions(
                headers: headers,
                body: UpsertSettingsRequest(settings: settings),
                timeoutInterval: 30
            )
        )
    }
}

enum SupabaseDate {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let formatter = ISO8601DateFormatter()

    static func timestamp(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? formatter.date(from: value)
    }

    static func dateOnly(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }
}
