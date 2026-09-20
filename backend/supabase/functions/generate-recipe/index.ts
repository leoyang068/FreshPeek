import { createAdminClient, safeEqual } from "../_shared/supabase.ts";
import { callQwenJSON } from "../_shared/qwen.ts";
import { errorResponse, handleOptions, jsonResponse } from "../_shared/http.ts";

interface RecipeRequest {
  food_ids?: string[];
  cuisine?: string;
}

interface InventoryFood {
  id: string;
  food_name: string;
  expiry_date: string;
}

interface RecipeResult {
  title: string;
  subtitle: string;
  used_foods: string[];
  extra_ingredients: string[];
  steps: string[];
}

function daysRemaining(expiryDate: string): number {
  const today = new Date();
  const utcToday = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  return Math.round((Date.parse(`${expiryDate}T00:00:00Z`) - utcToday) / 86_400_000);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function generateRecipe(foods: InventoryFood[], cuisine: string): Promise<RecipeResult> {
  const selected = foods.map((food) => ({
    name: food.food_name,
    days_remaining: daysRemaining(food.expiry_date),
  }));

  const prompt = `Create one practical home recipe using the selected refrigerated ingredients.
Cuisine preference: ${cuisine || "Any"}
Selected ingredients: ${JSON.stringify(selected)}

Rules:
1. Actually use at least one selected ingredient. Prioritize ingredients with fewer days remaining.
2. You do not need to use every selected ingredient. Do not force incompatible ingredients into one dish.
3. You may add common seasonings or supporting ingredients, but list them in extra_ingredients.
4. Give clear, concise steps that can be completed in a home kitchen.
5. All returned text must be English.
6. Return JSON only. Do not use Markdown or code fences.

JSON structure:
{
  "title": "recipe name",
  "subtitle": "estimated time and one short description",
  "used_foods": ["selected ingredient actually used"],
  "extra_ingredients": ["additional ingredient"],
  "steps": ["step 1", "step 2"]
}`;

  const result = await callQwenJSON<RecipeResult>({
    model: Deno.env.get("QWEN_TEXT_MODEL") ?? "qwen-plus",
    messages: [
      { role: "system", content: "You are a careful, practical home cook. Return valid JSON only, with all text in English." },
      { role: "user", content: prompt },
    ],
    maxTokens: 1400,
    temperature: 0.35,
  });

  const selectedNames = new Set(foods.map((food) => food.food_name));
  const usedFoods = Array.isArray(result.used_foods)
    ? result.used_foods.filter((name) => selectedNames.has(name))
    : [];

  if (!result.title || !Array.isArray(result.steps) || result.steps.length < 2 || usedFoods.length < 1) {
    throw new Error("The recipe did not use at least one selected ingredient. Please try again.");
  }

  return {
    title: result.title,
    subtitle: result.subtitle || "Prioritizes ingredients that expire soon.",
    used_foods: usedFoods,
    extra_ingredients: Array.isArray(result.extra_ingredients) ? result.extra_ingredients : [],
    steps: result.steps.filter((step) => typeof step === "string" && step.trim()),
  };
}

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

    const admin = createAdminClient();
    const body = await req.json() as RecipeRequest;
    const ids = [...new Set((body.food_ids ?? []).filter((id) => typeof id === "string"))].slice(0, 20);
    if (!ids.length) return jsonResponse({ error: "Select at least one ingredient." }, 400);

    const { data, error } = await admin
      .from("inventory_items")
      .select("id,food_name,expiry_date")
      .eq("owner_id", ownerID)
      .is("deleted_at", null)
      .in("id", ids);
    if (error) throw error;

    const foods = (data ?? []) as InventoryFood[];
    if (!foods.length) return jsonResponse({ error: "The selected ingredients are no longer in inventory." }, 409);

    const recipe = await generateRecipe(foods, body.cuisine ?? "Any");
    return jsonResponse(recipe);
  } catch (error) {
    return errorResponse(error, 500);
  }
});
