"""Upload one recognized refrigerator-door event to Supabase.

This module intentionally contains no Qwen key. It sends only the normalized
recognition result and each food's selected best frame to the ingest-event
Edge Function. Failed requests are queued on disk and retried later.
"""

from __future__ import annotations

import base64
import json
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

class FridgeCloudError(RuntimeError):
    pass


def _clean_json(raw: str | Mapping[str, Any]) -> dict[str, Any]:
    if isinstance(raw, Mapping):
        return dict(raw)
    value = raw.strip()
    if value.startswith("```"):
        value = value.removeprefix("```json").removeprefix("```")
        value = value.removesuffix("```").strip()
    start, end = value.find("{"), value.rfind("}")
    if start < 0 or end <= start:
        raise FridgeCloudError("LLM response does not contain a JSON object")
    return json.loads(value[start : end + 1])


def _normalize_foods(result: Mapping[str, Any]) -> list[dict[str, Any]]:
    foods = result.get("foods", [])
    if not foods:
        return []

    # New contract: foods is an array of per-food objects.
    if isinstance(foods[0], Mapping):
        normalized: list[dict[str, Any]] = []
        for food in foods:
            item = {
                "name": food.get("name"),
                "direction": food.get("direction"),
            }
            # Optional enrichment remains compatible with the previous contract,
            # but the MVP now requires only name + direction from the Pi.
            for key in (
                "canonical_name",
                "best_frame_index",
                "recognition_confidence",
                "target_clarity",
                "hand_occlusion",
                "appearance_summary",
                "trajectory",
            ):
                if food.get(key) is not None:
                    item[key] = food.get(key)
            normalized.append(item)
        return normalized

    # Compatibility with the original contract while fridge.py is being updated.
    directions = result.get("directions", [])
    confidence = result.get("confidence", "low")
    normalized = []
    for index, name in enumerate(foods):
        normalized.append(
            {
                "name": str(name),
                "canonical_name": str(name),
                "direction": directions[index] if index < len(directions) else "in",
                "best_frame_index": None,
                "recognition_confidence": confidence if confidence in {"high", "medium", "low"} else "low",
                "target_clarity": "poor",
                "hand_occlusion": "high",
                "appearance_summary": "Legacy recognition result without per-item image-quality details",
            }
        )
    return normalized


def _jpeg_data_url(frame: str | Path | Any, max_side: int = 1280) -> str:
    # The minimal MVP payload does not include images. Import OpenCV only when
    # an optional best-frame image actually needs to be encoded, so a freshly
    # installed Pi can still upload name + direction without python3-opencv.
    try:
        import cv2
    except ImportError as exc:
        raise FridgeCloudError(
            "OpenCV is required only when uploading a best-frame image"
        ) from exc

    image = cv2.imread(str(frame)) if isinstance(frame, (str, Path)) else frame
    if image is None:
        raise FridgeCloudError(f"Cannot read best frame: {frame}")

    height, width = image.shape[:2]
    scale = min(1.0, max_side / max(height, width))
    if scale < 1.0:
        image = cv2.resize(
            image,
            (max(1, round(width * scale)), max(1, round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )

    quality = 84
    encoded = None
    while quality >= 55:
        ok, candidate = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, quality])
        if not ok:
            raise FridgeCloudError("Best frame JPEG encoding failed")
        encoded = candidate
        if len(candidate) <= 1_900_000:
            break
        quality -= 8

    if encoded is None or len(encoded) > 2_000_000:
        raise FridgeCloudError("Best frame remains larger than 2 MB after compression")
    return "data:image/jpeg;base64," + base64.b64encode(encoded.tobytes()).decode("ascii")


class FridgeCloudUploader:
    def __init__(
        self,
        supabase_url: str | None = None,
        publishable_key: str | None = None,
        device_token: str | None = None,
        queue_dir: str | Path = "/home/leoy/fridge_pending",
        timeout_seconds: int = 145,
    ) -> None:
        self.supabase_url = (supabase_url or os.getenv("SUPABASE_URL", "")).rstrip("/")
        self.publishable_key = publishable_key or os.getenv("SUPABASE_PUBLISHABLE_KEY", "")
        self.device_token = device_token or os.getenv("FRIDGE_DEVICE_TOKEN", "")
        self.queue_dir = Path(queue_dir)
        self.timeout_seconds = timeout_seconds
        if not self.supabase_url or not self.publishable_key or not self.device_token:
            raise FridgeCloudError(
                "SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY and FRIDGE_DEVICE_TOKEN are required"
            )
        self.queue_dir.mkdir(parents=True, exist_ok=True)

    def upload_recognition(
        self,
        recognition: str | Mapping[str, Any],
        frames: Sequence[str | Path | Any],
        event_id: str | None = None,
    ) -> dict[str, Any]:
        result = _clean_json(recognition)
        foods = _normalize_foods(result)
        payload: dict[str, Any] = {
            "event_id": event_id or str(uuid.uuid4()),
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "foods": foods,
        }

        # Debug or legacy fields are optional and do not burden the minimal Pi
        # recognition contract.
        if "gesture" in result:
            payload["gesture"] = bool(result.get("gesture"))
        if result.get("reason"):
            payload["reason"] = str(result.get("reason"))
        if result.get("confidence") in {"high", "medium", "low"}:
            payload["confidence"] = result.get("confidence")

        for food in foods:
            index = food.get("best_frame_index")
            if isinstance(index, int) and 0 <= index < len(frames):
                try:
                    food["best_frame_base64"] = _jpeg_data_url(frames[index])
                except Exception as exc:  # Image failure must not discard the event.
                    food["image_upload_error"] = str(exc)

        try:
            response = self._post(payload)
            self.flush_pending(limit=3)
            return response
        except Exception:
            self._enqueue(payload)
            raise

    def flush_pending(self, limit: int = 10) -> int:
        sent = 0
        for path in sorted(self.queue_dir.glob("*.json"))[:limit]:
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
                self._post(payload)
                path.unlink()
                sent += 1
            except Exception:
                break
        return sent

    def _post(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        url = f"{self.supabase_url}/functions/v1/ingest-event"
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = Request(
            url,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "apikey": self.publishable_key,
                "x-fridge-device-token": self.device_token,
            },
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise FridgeCloudError(f"Cloud returned HTTP {exc.code}: {detail}") from exc
        except URLError as exc:
            raise FridgeCloudError(f"Cloud connection failed: {exc.reason}") from exc

    def _enqueue(self, payload: Mapping[str, Any]) -> None:
        event_id = str(payload["event_id"])
        destination = self.queue_dir / f"{int(time.time())}-{event_id}.json"
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, destination)


def upload_after_recognition(
    recognition_json: str | Mapping[str, Any],
    burst_frames: Sequence[str | Path | Any],
) -> dict[str, Any]:
    """Small integration entry point for /home/leoy/fridge.py."""
    return FridgeCloudUploader().upload_recognition(recognition_json, burst_frames)
