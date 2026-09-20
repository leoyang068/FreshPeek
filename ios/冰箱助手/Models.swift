import Foundation

enum ExpiryState: Int, Codable, Comparable, Sendable {
    case expired
    case expiringSoon
    case fresh

    nonisolated static func < (lhs: ExpiryState, rhs: ExpiryState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct FoodItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var canonicalName: String
    var addedDate: Date
    var shelfLifeDays: Int
    var lastUpdatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        canonicalName: String? = nil,
        addedDate: Date = .now,
        shelfLifeDays: Int,
        lastUpdatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.canonicalName = canonicalName ?? name
        self.addedDate = addedDate
        self.shelfLifeDays = max(1, shelfLifeDays)
        self.lastUpdatedAt = lastUpdatedAt
    }

    nonisolated var expiryDate: Date {
        Calendar.current.date(
            byAdding: .day,
            value: shelfLifeDays,
            to: Calendar.current.startOfDay(for: addedDate)
        ) ?? addedDate
    }

    nonisolated func daysRemaining(relativeTo date: Date = .now) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: expiryDate)
        ).day ?? 0
    }

    nonisolated func expiryState(thresholdDays: Int, relativeTo date: Date = .now) -> ExpiryState {
        let remaining = daysRemaining(relativeTo: date)
        if remaining < 0 { return .expired }
        if remaining <= thresholdDays { return .expiringSoon }
        return .fresh
    }

    nonisolated func statusText(relativeTo date: Date = .now) -> String {
        let remaining = daysRemaining(relativeTo: date)
        switch remaining {
        case ..<0:
            return "Expired \(-remaining) day\((-remaining) == 1 ? "" : "s") ago"
        case 0:
            return "Expires today"
        default:
            return "\(remaining) day\(remaining == 1 ? "" : "s") left"
        }
    }
}

enum Cuisine: String, CaseIterable, Codable, Identifiable, Sendable {
    case unrestricted = "Any"
    case chinese = "Chinese"
    case japanese = "Japanese"
    case korean = "Korean"
    case italian = "Italian"
    case mexican = "Mexican"
    case southeastAsian = "Southeast Asian"
    case indian = "Indian"
    case mediterranean = "Mediterranean"
    case americanHome = "American Home Cooking"
    case westernLight = "Western Casual"

    var id: String { rawValue }

    static func fromStoredValue(_ value: String) -> Cuisine? {
        if let cuisine = Cuisine(rawValue: value) { return cuisine }
        switch value {
        case "不限": return .unrestricted
        case "中餐": return .chinese
        case "日式": return .japanese
        case "韩式": return .korean
        case "意大利": return .italian
        case "墨西哥": return .mexican
        case "东南亚": return .southeastAsian
        case "印度": return .indian
        case "地中海": return .mediterranean
        case "美式家常": return .americanHome
        case "西式简餐": return .westernLight
        default: return nil
        }
    }
}

enum RemovalReason: String, Codable, Sendable {
    case automaticOut
    case manual
}

struct RemovedFoodRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let item: FoodItem
    let removedAt: Date
    let reason: RemovalReason

    init(item: FoodItem, removedAt: Date = .now, reason: RemovalReason) {
        id = UUID()
        self.item = item
        self.removedAt = removedAt
        self.reason = reason
    }
}

struct ShelfLifeRule: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var canonicalName: String
    var shelfLifeDays: Int
    var assumption: String
    var source: String

    init(
        id: UUID = UUID(),
        canonicalName: String,
        shelfLifeDays: Int,
        assumption: String = "Typical supermarket item stored under normal household refrigeration.",
        source: String = "llm"
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.shelfLifeDays = max(1, shelfLifeDays)
        self.assumption = assumption
        self.source = source
    }
}
