type TextPart = { type: "text"; text: string };
type ImagePart = { type: "image_url"; image_url: { url: string } };
export type QwenContent = string | Array<TextPart | ImagePart>;

export interface QwenMessage {
  role: "system" | "user" | "assistant";
  content: QwenContent;
}

interface QwenOptions {
  messages: QwenMessage[];
  model?: string;
  maxTokens?: number;
  temperature?: number;
}

function cleanJSON(value: string): string {
  const withoutFence = value
    .replace(/^\s*```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
  const start = withoutFence.indexOf("{");
  const end = withoutFence.lastIndexOf("}");
  return start >= 0 && end > start ? withoutFence.slice(start, end + 1) : withoutFence;
}

export async function callQwenJSON<T>(options: QwenOptions): Promise<T> {
  const apiKey = Deno.env.get("DASHSCOPE_API_KEY");
  if (!apiKey) throw new Error("DASHSCOPE_API_KEY is not configured");

  const baseURL = (Deno.env.get("DASHSCOPE_BASE_URL")
    ?? "https://dashscope-intl.aliyuncs.com/compatible-mode/v1").replace(/\/$/, "");
  const model = options.model ?? Deno.env.get("QWEN_TEXT_MODEL") ?? "qwen-plus";

  const response = await fetch(`${baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      messages: options.messages,
      temperature: options.temperature ?? 0.2,
      max_tokens: options.maxTokens ?? 1200,
      enable_thinking: false,
      response_format: { type: "json_object" },
    }),
  });

  const payload = await response.json().catch(() => null) as {
    choices?: Array<{ message?: { content?: string } }>;
    message?: string;
  } | null;

  if (!response.ok) {
    throw new Error(`Qwen request failed (${response.status}): ${payload?.message ?? "unknown error"}`);
  }

  const content = payload?.choices?.[0]?.message?.content;
  if (!content) throw new Error("Qwen returned an empty response");

  try {
    return JSON.parse(cleanJSON(content)) as T;
  } catch {
    throw new Error("Qwen did not return valid JSON");
  }
}

export function textPart(text: string): TextPart {
  return { type: "text", text };
}

export function imagePart(url: string): ImagePart {
  return { type: "image_url", image_url: { url } };
}
