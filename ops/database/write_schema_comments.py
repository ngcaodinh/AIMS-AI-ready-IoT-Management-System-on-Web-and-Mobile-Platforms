"""Sinh migration chú thích từ metadata và từ điển đã review, không sửa migration đã tồn tại."""

import json
from pathlib import Path

from schema_documentation import render_comments_migration


# Dùng đích cố định; ghi lần đầu hoặc so byte, không tự viết lại version đã phát hành.
def main():
    """Output: đường dẫn migration metadata. Errors: RuntimeError nếu file hiện có khác nội dung.
    Side effects: tạo0012 một lần từ manifest, không kết nối DB hoặc đọc environment.
    """
    root = Path(__file__).resolve().parents[2]
    directory = root / "backend/migrations/platform"
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    destination = directory / "0012_schema_comments.sql"
    content = render_comments_migration(manifest)
    if destination.exists():
        if destination.read_text(encoding="utf-8") != content:
            raise RuntimeError("Existing comments migration differs; add a new forward version instead")
    else:
        destination.write_text(content, encoding="utf-8", newline="\n")
    print(str(destination))


if __name__ == "__main__":
    main()
