import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

function readNamedKey(name: "SUPABASE_SECRET_KEYS" | "SUPABASE_PUBLISHABLE_KEYS"): string | null {
  const raw = Deno.env.get(name);
  if (!raw) return null;
  if (!raw.trim().startsWith("{")) return raw;

  try {
    const parsed = JSON.parse(raw) as Record<string, string>;
    return parsed.default ?? Object.values(parsed)[0] ?? null;
  } catch {
    return null;
  }
}

export function createAdminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const secretKey = readNamedKey("SUPABASE_SECRET_KEYS")
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    ?? Deno.env.get("SUPABASE_SECRET_KEY");

  if (!url || !secretKey) {
    throw new Error("Supabase server environment is incomplete");
  }

  return createClient(url, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function safeEqual(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [aHash, bHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  const aa = new Uint8Array(aHash);
  const bb = new Uint8Array(bHash);
  if (aa.length !== bb.length) return false;
  let result = 0;
  for (let index = 0; index < aa.length; index += 1) result |= aa[index] ^ bb[index];
  return result === 0;
}
