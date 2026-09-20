import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { createAdminClient, safeEqual } from "../_shared/supabase.ts";
import { callQwenJSON, imagePart, textPart, type QwenContent } from "../_shared/qwen.ts";
import { errorResponse, handleOptions, jsonResponse } from "../_shared/http.ts";
import {
  saveReferenceImage,
  signedImageURL,
  storeEventImage,
  type StoredImage,
} from "../_shared/images.ts";

type Confidence = "high" | "medium" | "low";
type Clarity = "good" | "usable" | "poor";
type Occlusion = "low" | "medium" | "high";

interface RecognizedFood {
  name: string;
  canonical_name?: string;
  direction: "in" | "out";
  best_frame_index?: number;
  best_frame_base64?: string;
  recognition_confidence?: Confidence;
  target_clarity?: Clarity;
  hand_occlusion?: Occlusion;
  appearance_summary?: string;
  trajectory?: string;
}

interface NormalizedRecognizedFood extends RecognizedFood {
  canonical_name: string;
  recognition_confidence: Confidence;
  target_clarity: Clarity;
  hand_occlusion: Occlusion;
}

interface IngestRequest {
  event_id: string;
  captured_at?: string;
  gesture?: boolean;
  foods: RecognizedFood[];
  reason?: string;
  confidence?: Confidence;
}

interface InventoryCandidate {
  id: string;
  food_name: string;
  canonical_name: string;
  expiry_date: string;
}

interface ReferenceImage {
  inventory_item_id: string;
  storage_path: string;
}

interface CandidateImage {
  inventory: InventoryCandidate;
  imageURL: string;
}

interface ApplyResult {
  event_record_id: string;
  action: "created" | "merged" | "deleted" | "restored" | "no_action";
  inventory_item_id: string | null;
  reason: string;
  duplicate: boolean;
}

function normalizedName(value: string): string {
  return value.trim().toLocaleLowerCase("en-US");
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function shelfLifeDays(
  admin: SupabaseClient,
  ownerID: string,
  canonicalName: string,
): Promise<number> {
  const { data: known } = await admin
    .from("shelf_life_rules")
    .select("shelf_life_days")
    .eq("owner_id", ownerID)
    .ilike("canonical_name", canonicalName)
    .limit(1);

  const existing = known?.[0]?.shelf_life_days;
  if (Number.isInteger(existing) && existing > 0) return existing;

  let days = 3;
  let assumption = "Typical supermarket item stored under normal household refrigeration; a conservative default was used because the model was unavailable.";
  let source = "system";

  try {
    const result = await callQwenJSON<{ shelf_life_days: number; assumption: string }>({
      model: Deno.env.get("QWEN_TEXT_MODEL") ?? "qwen-plus",
      messages: [
        {
          role: "system",
          content: "You provide conservative refrigerated shelf-life estimates for household food. Return valid JSON only, with all text in English.",
        },
        {
          role: "user",
          content: `Food: ${canonicalName}\nAssume a typical supermarket purchase, normal freshness, and standard household refrigeration. Return a conservative, common whole number of days. Return JSON only: {"shelf_life_days": integer, "assumption": "brief assumption in English"}`,
        },
      ],
      maxTokens: 250,
      temperature: 0.1,
    });
    if (Number.isInteger(result.shelf_life_days) && result.shelf_life_days >= 1 && result.shelf_life_days <= 365) {
      days = result.shelf_life_days;
      assumption = result.assumption || "Typical supermarket item stored under normal household refrigeration.";
      source = "llm";
    }
  } catch (error) {
    console.error("Shelf-life model fallback:", error);
  }

  await admin.from("shelf_life_rules").upsert({
    owner_id: ownerID,
    canonical_name: canonicalName,
    shelf_life_days: days,
    assumption,
    source,
    updated_at: new Date().toISOString(),
  }, { onConflict: "owner_id,canonical_name" });

  return days;
}

async function activeInventory(admin: SupabaseClient, ownerID: string): Promise<InventoryCandidate[]> {
  const { data, error } = await admin
    .from("inventory_items")
    .select("id,food_name,canonical_name,expiry_date")
    .eq("owner_id", ownerID)
    .is("deleted_at", null)
    .order("expiry_date", { ascending: true });
  if (error) throw error;
  return (data ?? []) as InventoryCandidate[];
}

async function candidateImages(
  admin: SupabaseClient,
  candidates: InventoryCandidate[],
): Promise<CandidateImage[]> {
  if (!candidates.length) return [];
  const { data, error } = await admin
    .from("inventory_reference_images")
    .select("inventory_item_id,storage_path,is_primary,created_at")
    .in("inventory_item_id", candidates.map((item) => item.id))
    .order("is_primary", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) throw error;

  const firstByItem = new Map<string, ReferenceImage>();
  for (const image of data ?? []) {
    if (!firstByItem.has(image.inventory_item_id)) firstByItem.set(image.inventory_item_id, image);
  }

  const result: CandidateImage[] = [];
  for (const inventory of candidates) {
    const reference = firstByItem.get(inventory.id);
    if (!reference) continue;
    const imageURL = await signedImageURL(admin, reference.storage_path);
    if (imageURL) result.push({ inventory, imageURL });
  }
  return result;
}

async function filterObviousMismatches(
  outgoingURL: string,
  candidates: CandidateImage[],
): Promise<Set<string>> {
  if (!candidates.length) return new Set();
  const content: QwenContent = [
    textPart(`The first image is the food being removed. The later images are same-name inventory candidates.
Only check for obvious incompatibility; do not require proof that two images show the exact same item. Mark a candidate incompatible only when its packaging color, shape, or food type clearly conflicts. Blur, viewing-angle changes, and partial occlusion are not sufficient reasons.
Return JSON only, with English text: {"clearly_incompatible_ids":["uuid"],"reason":"brief reason in English"}`),
    textPart("Current outgoing item:"),
    imagePart(outgoingURL),
  ];

  for (const candidate of candidates) {
    content.push(textPart(`Inventory candidate ID=${candidate.inventory.id}, name=${candidate.inventory.food_name}`));
    content.push(imagePart(candidate.imageURL));
  }

  const result = await callQwenJSON<{ clearly_incompatible_ids?: string[] }>({
    model: Deno.env.get("QWEN_VISION_MODEL") ?? "qwen3-vl-plus",
    messages: [
      { role: "system", content: "You carefully verify inventory images. Return valid JSON only, with all text in English." },
      { role: "user", content },
    ],
    maxTokens: 400,
    temperature: 0.05,
  });
  return new Set((result.clearly_incompatible_ids ?? []).filter(isUUID));
}

async function compareVisualBatch(
  outgoingURL: string,
  candidates: CandidateImage[],
): Promise<string | null> {
  if (!candidates.length) return null;
  const content: QwenContent = [
    textPart(`The first image is the outgoing target. Each later image represents one inventory item.
Choose a candidate only when food type, packaging, color, shape, and overall appearance are highly similar. Set visual_similarity to high only for a very strong match; return null when uncertain.
Return JSON only, with English text: {"matched_inventory_id":"uuid or null","visual_similarity":"high|medium|low","reason":"brief reason in English"}`),
    textPart("Current outgoing item:"),
    imagePart(outgoingURL),
  ];

  for (const candidate of candidates) {
    content.push(textPart(`Inventory candidate ID=${candidate.inventory.id}, recorded name=${candidate.inventory.food_name}`));
    content.push(imagePart(candidate.imageURL));
  }

  const result = await callQwenJSON<{
    matched_inventory_id?: string | null;
    visual_similarity?: "high" | "medium" | "low";
  }>({
    model: Deno.env.get("QWEN_VISION_MODEL") ?? "qwen3-vl-plus",
    messages: [
      { role: "system", content: "You are a conservative inventory-image matcher. Return valid JSON only, with all text in English." },
      { role: "user", content },
    ],
    maxTokens: 350,
    temperature: 0.05,
  });

  const candidateIDs = new Set(candidates.map((candidate) => candidate.inventory.id));
  return result.visual_similarity === "high"
      && result.matched_inventory_id
      && candidateIDs.has(result.matched_inventory_id)
    ? result.matched_inventory_id
    : null;
}

async function fullInventoryVisualMatch(
  admin: SupabaseClient,
  outgoingURL: string,
  inventory: InventoryCandidate[],
): Promise<string | null> {
  const images = await candidateImages(admin, inventory);
  if (!images.length) return null;

  const winners: CandidateImage[] = [];
  for (let start = 0; start < images.length; start += 8) {
    const batch = images.slice(start, start + 8);
    const winnerID = await compareVisualBatch(outgoingURL, batch);
    const winner = batch.find((candidate) => candidate.inventory.id === winnerID);
    if (winner) winners.push(winner);
  }

  if (winners.length === 1) return winners[0].inventory.id;
  if (winners.length > 1) return compareVisualBatch(outgoingURL, winners);
  return null;
}

async function matchOutgoing(
  admin: SupabaseClient,
  ownerID: string,
  food: NormalizedRecognizedFood,
  outgoingImage: StoredImage | null,
): Promise<{ id: string | null; reason: string }> {
  const inventory = await activeInventory(admin, ownerID);
  const canonical = normalizedName(food.canonical_name || food.name);
  const sameName = inventory.filter((candidate) => normalizedName(candidate.canonical_name) === canonical);
  const excludedIDs = new Set<string>();

  if (sameName.length && food.recognition_confidence === "high") {
    return { id: sameName[0].id, reason: "high_confidence_name_match" };
  }

  const outgoingURL = outgoingImage ? await signedImageURL(admin, outgoingImage.path) : null;
  if (sameName.length) {
    if (!outgoingURL) return { id: sameName[0].id, reason: "name_match_without_usable_comparison_image" };

    const images = await candidateImages(admin, sameName);
    if (!images.length) return { id: sameName[0].id, reason: "name_match_without_reference_image" };

    try {
      const incompatible = await filterObviousMismatches(outgoingURL, images);
      for (const id of incompatible) excludedIDs.add(id);
      const allowed = sameName.find((candidate) => !incompatible.has(candidate.id));
      if (allowed) return { id: allowed.id, reason: "name_match_no_obvious_visual_conflict" };
    } catch (error) {
      console.error("Obvious mismatch check failed; allowing name match:", error);
      return { id: sameName[0].id, reason: "name_match_visual_check_unavailable" };
    }
  }

  if (!outgoingURL) return { id: null, reason: "no_name_match_and_no_usable_image" };
  try {
    const visualID = await fullInventoryVisualMatch(
      admin,
      outgoingURL,
      inventory.filter((candidate) => !excludedIDs.has(candidate.id)),
    );
    return visualID
      ? { id: visualID, reason: "high_visual_similarity_fallback" }
      : { id: null, reason: "no_high_visual_similarity_candidate" };
  } catch (error) {
    console.error("Full inventory visual match failed:", error);
    return { id: null, reason: "visual_fallback_unavailable" };
  }
}

function normalizeFood(food: RecognizedFood): NormalizedRecognizedFood {
  if (!food.name?.trim()) throw new Error("Food name is required");
  if (!['in', 'out'].includes(food.direction)) throw new Error("Food direction must be in or out");
  if (food.recognition_confidence && !['high', 'medium', 'low'].includes(food.recognition_confidence)) {
    throw new Error("Invalid recognition confidence");
  }
  if (food.target_clarity && !['good', 'usable', 'poor'].includes(food.target_clarity)) {
    throw new Error("Invalid target clarity");
  }
  if (food.hand_occlusion && !['low', 'medium', 'high'].includes(food.hand_occlusion)) {
    throw new Error("Invalid hand occlusion");
  }

  return {
    ...food,
    name: food.name.trim(),
    canonical_name: (food.canonical_name || food.name).trim(),
    recognition_confidence: food.recognition_confidence ?? "medium",
    target_clarity: food.target_clarity ?? "usable",
    hand_occlusion: food.hand_occlusion ?? "medium",
  };
}

Deno.serve(async (req) => {
  const options = handleOptions(req);
  if (options) return options;
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const expectedToken = Deno.env.get("FRIDGE_DEVICE_TOKEN") ?? "";
    const providedToken = req.headers.get("x-fridge-device-token") ?? "";
    if (!expectedToken || !providedToken || !(await safeEqual(expectedToken, providedToken))) {
      return jsonResponse({ error: "Invalid fridge device token" }, 401);
    }

    const ownerID = Deno.env.get("FRIDGE_OWNER_ID") ?? "";
    if (!isUUID(ownerID)) throw new Error("FRIDGE_OWNER_ID is not configured");

    const body = await req.json() as IngestRequest;
    if (!isUUID(body.event_id)) return jsonResponse({ error: "event_id must be a UUID" }, 400);
    if (!Array.isArray(body.foods)) return jsonResponse({ error: "foods must be an array" }, 400);
    if (body.foods.length > 12) return jsonResponse({ error: "Too many foods in one event" }, 400);

    const admin = createAdminClient();
    const results: Array<ApplyResult & { food_index: number; name: string }> = [];

    for (let index = 0; index < body.foods.length; index += 1) {
      const food = normalizeFood(body.foods[index]);
      const canonicalName = food.canonical_name;

      let storedImage: StoredImage | null = null;
      try {
        storedImage = await storeEventImage(
          admin,
          ownerID,
          body.event_id,
          index,
          food.best_frame_base64,
        );
      } catch (error) {
        console.error(`Image upload failed for food ${index}:`, error);
      }

      let days: number | null = null;
      let matchID: string | null = null;
      let decisionReason = body.reason ?? "recognized_event";

      if (food.direction === "in") {
        days = await shelfLifeDays(admin, ownerID, canonicalName);
      } else {
        const match = await matchOutgoing(admin, ownerID, food, storedImage);
        matchID = match.id;
        decisionReason = match.reason;
      }

      const normalizedPayload = {
        ...food,
        canonical_name: canonicalName,
        gesture: Boolean(body.gesture),
        captured_at: body.captured_at ?? new Date().toISOString(),
      };

      const { data, error } = await admin.rpc("apply_fridge_item_event", {
        p_owner_id: ownerID,
        p_source_event_id: body.event_id,
        p_food_index: index,
        p_payload: normalizedPayload,
        p_match_inventory_id: matchID,
        p_shelf_life_days: days,
        p_decision_reason: decisionReason,
        p_best_frame_path: storedImage?.path ?? null,
      });
      if (error) throw error;

      const applied = data as ApplyResult;
      if (
        storedImage
        && food.direction === "in"
        && food.target_clarity !== "poor"
        && applied.inventory_item_id
        && applied.event_record_id
      ) {
        try {
          await saveReferenceImage(admin, {
            ownerID,
            inventoryItemID: applied.inventory_item_id,
            eventRecordID: applied.event_record_id,
            path: storedImage.path,
            frameIndex: food.best_frame_index ?? -1,
            targetClarity: food.target_clarity,
            handOcclusion: food.hand_occlusion,
          });
        } catch (error) {
          console.error(`Reference image save failed for food ${index}:`, error);
        }
      }

      results.push({ ...applied, food_index: index, name: food.name });
    }

    return jsonResponse({ event_id: body.event_id, results });
  } catch (error) {
    return errorResponse(error, 500);
  }
});
