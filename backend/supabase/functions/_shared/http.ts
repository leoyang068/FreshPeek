export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-fridge-device-token, x-fridge-app-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function errorResponse(error: unknown, status = 500): Response {
  if (error instanceof Error) {
    return jsonResponse({ error: error.message }, status);
  }

  if (error && typeof error === "object") {
    const details = error as Record<string, unknown>;
    const message = typeof details.message === "string"
      ? details.message
      : "Unexpected server error";
    const code = typeof details.code === "string" ? details.code : undefined;
    return jsonResponse({ error: message, ...(code ? { code } : {}) }, status);
  }

  return jsonResponse({ error: String(error) }, status);
}

export function handleOptions(req: Request): Response | null {
  if (req.method !== "OPTIONS") return null;
  return new Response("ok", { headers: corsHeaders });
}
