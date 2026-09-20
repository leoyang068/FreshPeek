"""Shared camera loop for OpenAI vision testing and production upload."""

from __future__ import annotations

import base64
import os
import time
from pathlib import Path

import numpy as np
from openai import OpenAI
from picamera2 import Picamera2


MODEL = "gpt-6-astra"
IMAGE_DETAIL = "high"

SAVE_DIR = "/home/leoy/burst"
OPEN_BRIGHTNESS_THRESHOLD = 85
CLOSE_BRIGHTNESS_THRESHOLD = 75
CONTROL_SETTLE_DELAY = 0.08
CLOSE_CONFIRM_FRAMES = 3
BURST_INTERVAL = 0.2
MAX_FRAMES = 60
SHUTTER = 5500

FRIDGE_ENV_PATH = Path("/home/leoy/fridge.env")
CLOUD_ENV_PATH = Path("/home/leoy/fridge_cloud.env")


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def img_to_b64(path: str) -> str:
    with open(path, "rb") as image_file:
        return base64.b64encode(image_file.read()).decode("ascii")


def build_content(image_paths: list[str], prompt: str) -> list[dict[str, object]]:
    content: list[dict[str, object]] = [
        {"type": "input_text", "text": prompt}
    ]
    last_index = len(image_paths) - 1
    for index, path in enumerate(image_paths):
        timing = "earliest" if index == 0 else "latest" if index == last_index else ""
        label = f"FRAME {index:02d}"
        if timing:
            label += f" ({timing})"
        content.append({"type": "input_text", "text": label})
        content.append(
            {
                "type": "input_image",
                "image_url": f"data:image/jpeg;base64,{img_to_b64(path)}",
                "detail": IMAGE_DETAIL,
            }
        )
    return content


def recognize(
    client: OpenAI,
    image_paths: list[str],
    prompt: str,
) -> str:
    response = client.responses.create(
        model=MODEL,
        reasoning={"effort": "low"},
        input=[
            {
                "role": "user",
                "content": build_content(image_paths, prompt),
            }
        ],
        max_output_tokens=1000,
        store=False,
    )
    result = response.output_text
    if not result:
        raise RuntimeError("OpenAI returned an empty recognition result")
    return result


def run(*, enable_cloud_upload: bool, prompt_path: Path) -> None:
    load_env_file(FRIDGE_ENV_PATH)
    load_env_file(CLOUD_ENV_PATH)

    api_key = os.getenv("OPENAI_API_KEY", "")
    if not api_key:
        raise RuntimeError(
            "OPENAI_API_KEY is missing. Add it to /home/leoy/fridge.env"
        )
    if not prompt_path.exists():
        raise RuntimeError(f"Recognition prompt is missing: {prompt_path}")

    recognition_prompt = prompt_path.read_text(encoding="utf-8")
    os.makedirs(SAVE_DIR, exist_ok=True)
    client = OpenAI(api_key=api_key, timeout=180.0, max_retries=2)

    cloud_uploader = None
    if enable_cloud_upload:
        from fridge_cloud import FridgeCloudUploader

        cloud_uploader = FridgeCloudUploader()

    picam = Picamera2()
    picam.configure(picam.create_preview_configuration(main={"size": (640, 480)}))
    picam.start()
    time.sleep(2)

    init_b = np.mean(picam.capture_array())
    door_open = init_b > OPEN_BRIGHTNESS_THRESHOLD
    print(
        f"Startup brightness={init_b:.0f}, "
        f"door={'open' if door_open else 'closed'}"
    )
    mode = "production + Supabase" if enable_cloud_upload else "recognition-only test"
    print(f"OpenAI model={MODEL}; mode={mode}")
    print("Waiting for door to open... (Ctrl+C to quit)")

    try:
        while True:
            brightness = np.mean(picam.capture_array())

            if brightness > OPEN_BRIGHTNESS_THRESHOLD and not door_open:
                door_open = True
                print(f"Door opened (brightness={brightness:.0f})")

                picam.set_controls(
                    {
                        "ExposureTime": SHUTTER,
                        "AeEnable": False,
                        "AnalogueGain": 0.0,
                    }
                )
                time.sleep(CONTROL_SETTLE_DELAY)

                for old in os.listdir(SAVE_DIR):
                    old_path = os.path.join(SAVE_DIR, old)
                    if os.path.isfile(old_path):
                        os.remove(old_path)

                paths: list[str] = []
                frame_index = 0
                closed_frame_count = 0
                print(f"Shooting at shutter {SHUTTER}us until door closes...")

                while frame_index < MAX_FRAMES:
                    request = picam.capture_request()
                    try:
                        frame = request.make_array("main")
                        frame_brightness = np.mean(frame)
                        if frame_brightness < CLOSE_BRIGHTNESS_THRESHOLD:
                            closed_frame_count += 1
                            if closed_frame_count >= CLOSE_CONFIRM_FRAMES:
                                break
                        else:
                            closed_frame_count = 0
                            frame_path = os.path.join(
                                SAVE_DIR,
                                f"shot_{frame_index:02d}.jpg",
                            )
                            request.save("main", frame_path)
                            paths.append(frame_path)
                            frame_index += 1
                    finally:
                        request.release()
                    time.sleep(BURST_INTERVAL)

                picam.set_controls({"AeEnable": True})
                time.sleep(0.5)
                door_open = False
                print(f"Captured {len(paths)} frames")

                if not paths:
                    print("No frames, skip")
                    print("Waiting for door to open...")
                    continue

                print(f"Sending all {len(paths)} labeled frames to OpenAI...")
                try:
                    result = recognize(client, paths, recognition_prompt)
                    print("RESULT:", result)

                    if cloud_uploader is not None:
                        try:
                            cloud_result = cloud_uploader.upload_recognition(result, paths)
                            print("CLOUD:", cloud_result)
                        except Exception as exc:
                            print(
                                "Cloud sync temporarily failed; "
                                f"queued for retry: {exc}"
                            )
                except Exception as exc:
                    print("Recognition error:", exc)

                print("Waiting for door to open...")

            elif brightness < CLOSE_BRIGHTNESS_THRESHOLD and door_open:
                door_open = False

            time.sleep(0.2)

    except KeyboardInterrupt:
        print("\nStopped")
    finally:
        picam.stop()
