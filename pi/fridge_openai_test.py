from pathlib import Path

from fridge_openai_runner import run


if __name__ == "__main__":
    run(
        enable_cloud_upload=False,
        prompt_path=Path("/home/leoy/recognition_prompt_openai_direction_test.txt"),
    )
