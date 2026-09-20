from pathlib import Path

from picamera2 import Picamera2
from openai import OpenAI
import numpy as np
import base64
import time
import os

# ---- Config ----
BASE_URL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
MODEL = "qwen3-vl-plus"
ENABLE_CLOUD_UPLOAD = False  # Recognition-only test; do not update Supabase.

SAVE_DIR = "/home/leoy/burst"
OPEN_BRIGHTNESS_THRESHOLD = 85
CLOSE_BRIGHTNESS_THRESHOLD = 75
CONTROL_SETTLE_DELAY = 0.08  # about 2-3 frames at 30 fps
CLOSE_CONFIRM_FRAMES = 3
BURST_INTERVAL = 0.2        # seconds between shots
MAX_FRAMES = 60             # safety cap: stop after this many frames
SHUTTER = 5500              # microseconds; reduces motion blur during burst

FRIDGE_ENV_PATH = Path("/home/leoy/fridge.env")
CLOUD_ENV_PATH = Path("/home/leoy/fridge_cloud.env")
PROMPT_PATH = Path("/home/leoy/recognition_prompt_direction_test.txt")
# ----------------


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


load_env_file(FRIDGE_ENV_PATH)
load_env_file(CLOUD_ENV_PATH)

api_key = os.getenv("DASHSCOPE_API_KEY", "")
if not api_key:
    raise RuntimeError(
        "DASHSCOPE_API_KEY is missing. Add it to /home/leoy/fridge.env"
    )
if not PROMPT_PATH.exists():
    raise RuntimeError(f"Recognition prompt is missing: {PROMPT_PATH}")

recognition_prompt = PROMPT_PATH.read_text(encoding="utf-8")

os.makedirs(SAVE_DIR, exist_ok=True)
client = OpenAI(api_key=api_key, base_url=BASE_URL)
cloud_uploader = None
if ENABLE_CLOUD_UPLOAD:
    from fridge_cloud import FridgeCloudUploader

    cloud_uploader = FridgeCloudUploader()

picam = Picamera2()
picam.configure(picam.create_preview_configuration(main={"size": (640, 480)}))
picam.start()
time.sleep(2)  # warm up

# Initialize from actual brightness to avoid a false opening event at startup.
init_b = np.mean(picam.capture_array())
door_open = init_b > OPEN_BRIGHTNESS_THRESHOLD
print(
    f"Startup brightness={init_b:.0f}, "
    f"door={'open' if door_open else 'closed'}"
)
print("Waiting for door to open... (Ctrl+C to quit)")


def img_to_b64(path: str) -> str:
    with open(path, "rb") as image_file:
        return base64.b64encode(image_file.read()).decode("ascii")


def recognize(image_paths: list[str]) -> str:
    content = []
    for path in image_paths:
        content.append(
            {
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/jpeg;base64,{img_to_b64(path)}"
                },
            }
        )

    # The frame order here is exactly the order used by best_frame_index.
    content.append({"type": "text", "text": recognition_prompt})

    response = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": content}],
    )
    result = response.choices[0].message.content
    if not result:
        raise RuntimeError("Qwen returned an empty recognition result")
    return result


try:
    while True:
        brightness = np.mean(picam.capture_array())

        # Door just opened.
        if brightness > OPEN_BRIGHTNESS_THRESHOLD and not door_open:
            door_open = True
            print(f"Door opened (brightness={brightness:.0f})")

            # Apply the proven fast shutter immediately. The camera is already
            # running and warm, so only allow a few frame periods for controls.
            picam.set_controls(
                {
                    "ExposureTime": SHUTTER,
                    "AeEnable": False,
                    "AnalogueGain": 0.0,
                }
            )
            time.sleep(CONTROL_SETTLE_DELAY)

            # Clear frames from the previous door event.
            for old in os.listdir(SAVE_DIR):
                old_path = os.path.join(SAVE_DIR, old)
                if os.path.isfile(old_path):
                    os.remove(old_path)

            # Keep shooting until the door closes or the safety cap is reached.
            paths: list[str] = []
            frame_index = 0
            closed_frame_count = 0
            print(f"Shooting at shutter {SHUTTER}us until door closes...")
            while frame_index < MAX_FRAMES:
                # The same captured frame is used for local brightness detection
                # and, while the door is open, as the frame sent to Qwen.
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

            # Restore auto exposure so brightness detection continues to work.
            picam.set_controls({"AeEnable": True})
            time.sleep(0.5)
            door_open = False
            print(f"Captured {len(paths)} frames")

            if not paths:
                print("No frames, skip")
                print("Waiting for door to open...")
                continue

            print(f"Sending all {len(paths)} frames to Qwen...")
            try:
                result = recognize(paths)
                print("RESULT:", result)

                if cloud_uploader is not None:
                    try:
                        cloud_result = cloud_uploader.upload_recognition(result, paths)
                        print("CLOUD:", cloud_result)
                    except Exception as exc:
                        # fridge_cloud.py persists the event and retries it later.
                        print(f"Cloud sync temporarily failed; queued for retry: {exc}")
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
