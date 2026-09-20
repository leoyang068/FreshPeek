import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export const IMAGE_BUCKET = "inventory-reference-images";

export interface StoredImage {
  path: string;
  contentType: string;
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export async function storeEventImage(
  admin: SupabaseClient,
  ownerID: string,
  eventID: string,
  foodIndex: number,
  base64OrDataURL?: string | null,
): Promise<StoredImage | null> {
  if (!base64OrDataURL) return null;

  const match = base64OrDataURL.match(/^data:(image\/(?:jpeg|png|webp));base64,(.+)$/s);
  const contentType = match?.[1] ?? "image/jpeg";
  const raw = match?.[2] ?? base64OrDataURL;
  const bytes = decodeBase64(raw);
  if (bytes.byteLength > 2_097_152) throw new Error("Best frame exceeds the 2 MB limit");

  const extension = contentType === "image/png" ? "png" : contentType === "image/webp" ? "webp" : "jpg";
  const path = `${ownerID}/events/${eventID}/${foodIndex}.${extension}`;
  const { error } = await admin.storage.from(IMAGE_BUCKET).upload(path, bytes, {
    contentType,
    upsert: true,
  });
  if (error) throw error;
  return { path, contentType };
}

export async function signedImageURL(admin: SupabaseClient, path: string): Promise<string | null> {
  const { data, error } = await admin.storage.from(IMAGE_BUCKET).createSignedUrl(path, 300);
  return error ? null : data.signedUrl;
}

export async function saveReferenceImage(
  admin: SupabaseClient,
  input: {
    ownerID: string;
    inventoryItemID: string;
    eventRecordID: string;
    path: string;
    frameIndex: number;
    targetClarity: string;
    handOcclusion: string;
  },
): Promise<void> {
  const { data: existing } = await admin
    .from("inventory_reference_images")
    .select("id,storage_path,is_primary,created_at")
    .eq("inventory_item_id", input.inventoryItemID)
    .order("created_at", { ascending: true });

  const isPrimary = !existing?.some((image) => image.is_primary);
  const { error } = await admin.from("inventory_reference_images").upsert({
    owner_id: input.ownerID,
    inventory_item_id: input.inventoryItemID,
    storage_path: input.path,
    source_event_id: input.eventRecordID,
    frame_index: input.frameIndex,
    target_clarity: input.targetClarity,
    hand_occlusion: input.handOcclusion,
    is_primary: isPrimary,
  }, { onConflict: "storage_path" });
  if (error) throw error;

  const { data: allImages } = await admin
    .from("inventory_reference_images")
    .select("id,storage_path,is_primary,target_clarity,hand_occlusion,created_at")
    .eq("inventory_item_id", input.inventoryItemID);

  if (!allImages || allImages.length <= 3) return;

  const quality = (image: Record<string, unknown>): number => {
    const clarity = image.target_clarity === "good" ? 3 : image.target_clarity === "usable" ? 2 : 1;
    const occlusion = image.hand_occlusion === "low" ? 3 : image.hand_occlusion === "medium" ? 2 : 1;
    const primary = image.is_primary ? 100 : 0;
    return primary + clarity * 10 + occlusion;
  };

  const removable = [...allImages]
    .sort((a, b) => quality(a) - quality(b))
    .slice(0, allImages.length - 3);

  const paths = removable.map((image) => image.storage_path as string);
  await admin.from("inventory_reference_images").delete().in("id", removable.map((image) => image.id));
  if (paths.length) await admin.storage.from(IMAGE_BUCKET).remove(paths);
}
