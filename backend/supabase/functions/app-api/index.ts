import { createAdminClient, safeEqual } from "../_shared/supabase.ts";
import { errorResponse, handleOptions, jsonResponse } from "../_shared/http.ts";

interface AppRequest {
  action?: string;
  item_id?: string;
  item?: Record<string, unknown>;
  deleted_at?: string | null;
  updated_at?: string;
  settings?: Record<string, unknown>;
}

function isUUID(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${field} is required`);
  return value.trim();
}

function requiredInteger(value: unknown, field: string, minimum: number, maximum: number): number {
  if (!Number.isInteger(value) || Number(value) < minimum || Number(value) > maximum) {
    throw new Error(`${field} is invalid`);
  }
  return Number(value);
}

function inventoryInsert(ownerID: string, item: Record<string, unknown>) {
  if (!isUUID(item.id)) throw new Error("item.id must be a UUID");
  return {
    id: item.id,
    owner_id: ownerID,
    food_name: requiredString(item.food_name, "food_name"),
    canonical_name: requiredString(item.canonical_name, "canonical_name"),
    added_at: requiredString(item.added_at, "added_at"),
    last_added_at: requiredString(item.last_added_at, "last_added_at"),
    shelf_life_days: requiredInteger(item.shelf_life_days, "shelf_life_days", 1, 3650),
    expiry_date: requiredString(item.expiry_date, "expiry_date"),
    user_corrected: Boolean(item.user_corrected),
    updated_at: requiredString(item.updated_at, "updated_at"),
  };
}

function inventoryUpdate(item: Record<string, unknown>) {
  return {
    food_name: requiredString(item.food_name, "food_name"),
    canonical_name: requiredString(item.canonical_name, "canonical_name"),
    added_at: requiredString(item.added_at, "added_at"),
    last_added_at: requiredString(item.last_added_at, "last_added_at"),
    shelf_life_days: requiredInteger(item.shelf_life_days, "shelf_life_days", 1, 3650),
    expiry_date: requiredString(item.expiry_date, "expiry_date"),
    user_corrected: Boolean(item.user_corrected),
    updated_at: requiredString(item.updated_at, "updated_at"),
  };
}

const legacyInventoryNames = [
  { from: "菠菜", foodName: "Spinach", canonicalName: "spinach" },
  { from: "牛肉", foodName: "Beef", canonicalName: "beef" },
  { from: "绿叶菜", foodName: "Leafy Greens", canonicalName: "leafy greens" },
  { from: "红色塑料袋装物品", foodName: "Red Bagged Food", canonicalName: "packaged food" },
  { from: "白色纸盒装乳制品", foodName: "Dairy Product in a White Carton", canonicalName: "dairy" },
  { from: "橙色盖子罐装食品", foodName: "Canned Food with an Orange Lid", canonicalName: "opened canned food" },
  { from: "牛奶壶", foodName: "Milk Jug", canonicalName: "milk" },
  { from: "红色盖子罐装酱料", foodName: "Jarred Sauce with a Red Lid", canonicalName: "sauce" },
  { from: "透明塑料盒装肉制品", foodName: "Meat in a Clear Plastic Container", canonicalName: "meat" },
  { from: "草莓", foodName: "Strawberries", canonicalName: "strawberries" },
  { from: "罐头食品", foodName: "Canned Food", canonicalName: "canned food" },
  { from: "香菜", foodName: "Cilantro", canonicalName: "cilantro" },
  { from: "蘑菇", foodName: "Mushrooms", canonicalName: "mushrooms" },
  { from: "lime", foodName: "Lime", canonicalName: "lime" },
] as const;

const legacyRuleNames = [
  { from: "菠菜", to: "spinach" },
  { from: "牛肉", to: "beef" },
  { from: "绿叶菜", to: "leafy greens" },
  { from: "包装食品", to: "packaged food" },
  { from: "乳制品", to: "dairy" },
  { from: "罐装食品", to: "opened canned food" },
  { from: "牛奶", to: "milk" },
  { from: "酱料", to: "sauce" },
  { from: "肉制品", to: "meat" },
  { from: "草莓", to: "strawberries" },
  { from: "罐头食品", to: "canned food" },
  { from: "香菜", to: "cilantro" },
  { from: "蘑菇", to: "mushrooms" },
] as const;

const legacyCuisineNames: Record<string, string> = {
  "不限": "Any",
  "中餐": "Chinese",
  "日式": "Japanese",
  "韩式": "Korean",
  "意大利": "Italian",
  "墨西哥": "Mexican",
  "东南亚": "Southeast Asian",
  "印度": "Indian",
  "地中海": "Mediterranean",
  "美式家常": "American Home Cooking",
  "西式简餐": "Western Casual",
};

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const expectedToken = Deno.env.get("FRIDGE_APP_TOKEN") ?? "";
    const providedToken = req.headers.get("x-fridge-app-token") ?? "";
    if (!expectedToken || !providedToken || !(await safeEqual(expectedToken, providedToken))) {
      return jsonResponse({ error: "Invalid fridge app token" }, 401);
    }

    const ownerID = Deno.env.get("FRIDGE_OWNER_ID") ?? "";
    if (!isUUID(ownerID)) throw new Error("FRIDGE_OWNER_ID is not configured");

    const body = await req.json() as AppRequest;
    const admin = createAdminClient();

    switch (body.action) {
      case "bootstrap": {
        const [inventoryResult, rulesResult, settingsResult] = await Promise.all([
          admin
            .from("inventory_items")
            .select("id,owner_id,food_name,canonical_name,added_at,shelf_life_days,updated_at,deleted_at")
            .eq("owner_id", ownerID),
          admin
            .from("shelf_life_rules")
            .select("id,canonical_name,shelf_life_days,assumption,source")
            .eq("owner_id", ownerID),
          admin
            .from("user_settings")
            .select("expiring_threshold_days,cuisine,notifications_enabled")
            .eq("owner_id", ownerID)
            .limit(1),
        ]);
        if (inventoryResult.error) throw inventoryResult.error;
        if (rulesResult.error) throw rulesResult.error;
        if (settingsResult.error) throw settingsResult.error;
        return jsonResponse({
          inventory_items: inventoryResult.data ?? [],
          shelf_life_rules: rulesResult.data ?? [],
          settings: settingsResult.data?.[0] ?? null,
        });
      }

      case "migrate_legacy_english": {
        for (const mapping of legacyInventoryNames) {
          const { error } = await admin
            .from("inventory_items")
            .update({
              food_name: mapping.foodName,
              canonical_name: mapping.canonicalName,
              updated_at: new Date().toISOString(),
            })
            .eq("owner_id", ownerID)
            .eq("food_name", mapping.from);
          if (error) throw error;
        }

        for (const mapping of legacyRuleNames) {
          const { error } = await admin
            .from("shelf_life_rules")
            .update({
              canonical_name: mapping.to,
              assumption: "Typical supermarket item stored under normal household refrigeration.",
              updated_at: new Date().toISOString(),
            })
            .eq("owner_id", ownerID)
            .eq("canonical_name", mapping.from);
          if (error) throw error;
        }

        const { error: assumptionError } = await admin
          .from("shelf_life_rules")
          .update({
            assumption: "Typical supermarket item stored under normal household refrigeration.",
            updated_at: new Date().toISOString(),
          })
          .eq("owner_id", ownerID);
        if (assumptionError) throw assumptionError;

        const { data: settings, error: settingsReadError } = await admin
          .from("user_settings")
          .select("cuisine")
          .eq("owner_id", ownerID)
          .limit(1);
        if (settingsReadError) throw settingsReadError;
        const existingCuisine = settings?.[0]?.cuisine;
        const englishCuisine = legacyCuisineNames[existingCuisine] ?? existingCuisine;
        if (englishCuisine && englishCuisine !== existingCuisine) {
          const { error } = await admin
            .from("user_settings")
            .update({ cuisine: englishCuisine, updated_at: new Date().toISOString() })
            .eq("owner_id", ownerID);
          if (error) throw error;
        }

        return jsonResponse({ ok: true });
      }

      case "insert_item": {
        if (!body.item) throw new Error("item is required");
        const payload = inventoryInsert(ownerID, body.item);
        const { error } = await admin.from("inventory_items").insert(payload);
        if (error) throw error;
        return jsonResponse({ ok: true });
      }

      case "update_item": {
        if (!isUUID(body.item_id)) throw new Error("item_id must be a UUID");
        if (!body.item) throw new Error("item is required");
        const payload = inventoryUpdate(body.item);
        const { error } = await admin
          .from("inventory_items")
          .update(payload)
          .eq("owner_id", ownerID)
          .eq("id", body.item_id);
        if (error) throw error;
        return jsonResponse({ ok: true });
      }

      case "set_deleted": {
        if (!isUUID(body.item_id)) throw new Error("item_id must be a UUID");
        const updatedAt = requiredString(body.updated_at, "updated_at");
        const deletedAt = body.deleted_at ?? null;
        if (deletedAt !== null && typeof deletedAt !== "string") {
          throw new Error("deleted_at is invalid");
        }
        const { error } = await admin
          .from("inventory_items")
          .update({ deleted_at: deletedAt, updated_at: updatedAt })
          .eq("owner_id", ownerID)
          .eq("id", body.item_id);
        if (error) throw error;
        return jsonResponse({ ok: true });
      }

      case "upsert_settings": {
        const settings = body.settings;
        if (!settings) throw new Error("settings is required");
        const cuisine = requiredString(settings.cuisine, "cuisine");
        const threshold = requiredInteger(
          settings.expiring_threshold_days,
          "expiring_threshold_days",
          1,
          14,
        );
        const updatedAt = requiredString(settings.updated_at, "updated_at");
        const { error } = await admin.from("user_settings").upsert({
          owner_id: ownerID,
          expiring_threshold_days: threshold,
          cuisine,
          notifications_enabled: Boolean(settings.notifications_enabled),
          updated_at: updatedAt,
        }, { onConflict: "owner_id" });
        if (error) throw error;
        return jsonResponse({ ok: true });
      }

      default:
        return jsonResponse({ error: "Unknown action" }, 400);
    }
  } catch (error) {
    return errorResponse(error, 500);
  }
});
