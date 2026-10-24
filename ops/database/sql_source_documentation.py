"""Chú thích source SQL theo metadata thật, giữ riêng byte migration đã áp và so token không đổi logic."""

import hashlib
import json
import re
import textwrap
from pathlib import Path

import schema_documentation as documentation


ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "backend/migrations/platform"
ARCHIVE = DIRECTORY / "applied_sql"
DOLLAR_DELIMITER = re.compile(r"\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$")
SQL_WORD = re.compile(r"[A-Za-z_][A-Za-z_0-9$]*|[0-9]+(?:\.[0-9]+)?")


# Lexer phân biệt literal/dollar-body với comment; không dùng regex xóa nhầm -- hoặc /* trong chuỗi.
def sql_tokens(statement):
    """Tách token cùng vị trí để đối chiếu SQL trước/sau chỉ thêm comment.
    Input
    Param: statement — source SQL tin cậy, không đọc credential hay environment.
    Output: danh sách (token, start, end), bỏ khoảng trắng và comment ngoài literal.
    Errors: ValueError nếu comment/literal chưa kết thúc; không chấp nhận source phân tích dở.
    """
    result = []
    offset = 0
    while offset < len(statement):
        start = offset
        if statement[offset].isspace():
            offset += 1
            continue
        if statement.startswith("--", offset):
            newline = statement.find("\n", offset)
            offset = len(statement) if newline < 0 else newline + 1
            continue
        if statement.startswith("/*", offset):
            depth = 1
            offset += 2
            while depth and offset < len(statement):
                if statement.startswith("/*", offset):
                    depth += 1
                    offset += 2
                elif statement.startswith("*/", offset):
                    depth -= 1
                    offset += 2
                else:
                    offset += 1
            if depth:
                raise ValueError("Unterminated SQL block comment")
            continue
        # match tại offset tránh copy toàn bộ phần đuôi SQL cho mỗi token của snapshot lớn.
        delimiter = DOLLAR_DELIMITER.match(statement,offset)
        if delimiter:
            end = statement.find(delimiter[0], offset + len(delimiter[0]))
            if end < 0:
                raise ValueError("Unterminated dollar-quoted SQL body")
            offset = end + len(delimiter[0])
        elif statement[offset] in "'\"" or statement.startswith(("E'","e'"),offset):
            escaped = statement[offset] in "eE"
            if escaped:
                offset += 1
            quote = statement[offset]
            offset += 1
            while offset < len(statement):
                if escaped and statement[offset] == "\\":
                    offset += 2
                elif statement[offset] == quote:
                    offset += 1
                    if offset < len(statement) and statement[offset] == quote:
                        offset += 1
                    else:
                        break
                else:
                    offset += 1
            else:
                raise ValueError("Unterminated quoted SQL value")
        else:
            word = SQL_WORD.match(statement,offset)
            offset += len(word[0]) if word else 1
        result.append((statement[start:offset], start, offset))
    return result


# Mọi thay đổi executable phải là forward migration; chỉ khoảng trắng/comment được khác archive.
def executable_source(path):
    """Chọn byte source đã áp, đồng thời chứng minh bản chú thích có cùng token SQL.
    Input
    Param: path — numbered migration ở thư mục canonical.
    Output: Path archive nếu đã có bản chú thích; nếu chưa thì chính path.
    Errors: RuntimeError nếu executable token khác; không đổi checksum ledger để che drift.
    """
    archived = path.parent / "applied_sql" / path.name
    if not archived.is_file():
        return path
    original = archived.read_text(encoding="utf-8")
    visible = path.read_text(encoding="utf-8")
    if [token[0] for token in sql_tokens(original)] != [token[0] for token in sql_tokens(visible)]:
        raise RuntimeError("Annotated migration changed executable SQL: " + path.name)
    return archived


# Mô tả kiểu không gán tính chất bảo mật mà type không bảo đảm, ví dụ UUID hoặc bytea.
def type_description(column):
    """Input
    Param: column — tên/kiểu thực tế từ manifest PostgreSQL.
    Output: giải thích kiểu dữ liệu và giới hạn thường dễ bị hiểu sai.
    """
    descriptions = {
        "uuid": "UUID: định danh 128 bit; kiểu dữ liệu không tự sinh ID và không tự bảo đảm khó đoán, cần cách sinh UUID phù hợp.",
        "timestamp with time zone": "timestamptz: lưu thời điểm tuyệt đối theo UTC, hiển thị theo TimeZone của phiên; không lưu tên múi giờ gốc.",
        "text": "text: chuỗi Unicode có độ dài biến đổi; kiểu này không tự trim, đổi chữ thường hoặc xác minh định dạng nghiệp vụ.",
        "boolean": "boolean: cờ logic true/false; NULL là trạng thái riêng nếu cột cho phép.",
        "integer": "integer: số nguyên có dấu 32 bit; CHECK giới hạn miền nghiệp vụ thay vì chỉ dựa phạm vi kiểu.",
        "bigint": "bigint: số nguyên có dấu 64 bit, phù hợp bộ đếm/generation tăng lâu dài; không tự tăng nếu chưa có cơ chế cấp giá trị.",
        "double precision": "double precision: số thực dấu phẩy động 64 bit, có sai số biểu diễn; kiểm finite/range theo CHECK và validator.",
        "bytea": "bytea: dãy byte nhị phân; tên digest/ciphertext mô tả mục đích, bản thân kiểu không băm hoặc mã hóa dữ liệu.",
        "jsonb": "jsonb: tài liệu JSON lưu dạng nhị phân; kiểm object/scalar không thay validation đầy đủ cấu trúc và tham chiếu nghiệp vụ.",
        "xid8": "xid8: transaction ID 64 bit của PostgreSQL, dùng marker nội bộ; không dùng làm định danh nghiệp vụ hoặc token bảo mật.",
    }
    return descriptions.get(column["type"], "Kiểu PostgreSQL " + column["type"] + ": lưu giá trị theo miền kiểu, kết hợp ràng buộc bên dưới.")


# Ràng buộc lấy từ engine hiện hành, nên mô tả rõ khi một CHECK/FK được bổ sung ở migration sau.
def column_comments(table, column):
    """Sinh công dụng và giải thích type/NULL/default/key/check cho đúng một thuộc tính.
    Input
    Param: table — metadata bảng cùng constraints đã lấy từ PostgreSQL.
    Param: column — thuộc tính của bảng, gồm default và nullability thực tế.
    Output: các dòng -- tiếng Việt dùng ngay trước column definition.
    """
    name = column["name"]
    purpose = documentation.COLUMN_OVERRIDES.get(table["name"], {}).get(name, documentation.COLUMN_DESCRIPTIONS.get(name))
    if not purpose:
        raise ValueError("Missing documented column: " + table["name"] + "." + name)
    notes = [purpose, type_description(column)]
    not_null_note="NOT NULL: bắt buộc có giá trị." + (" Chuỗi rỗng vẫn cần CHECK riêng." if column["type"]=="text" else "")
    notes.append(not_null_note if column["nullable"] == "NO" else
                 "Cho phép NULL: chưa có/không áp dụng giá trị theo nghiệp vụ; không đồng nghĩa chuỗi rỗng hoặc số 0.")
    if column.get("default") is not None:
        default = column["default"]
        explanation = "giá trị dùng khi INSERT bỏ qua cột; không thay NULL được truyền tường minh và không tự áp lại khi UPDATE."
        if "transaction_timestamp()" in default or "now()" in default:
            explanation = "thời điểm bắt đầu transaction, giữ nguyên trong transaction; không phải đồng hồ thay đổi theo từng statement."
        elif "clock_timestamp()" in default:
            explanation = "đồng hồ thực tại thời điểm gán mặc định, có thể thay đổi giữa các lần ghi trong cùng transaction."
        notes.append("DEFAULT " + default + ": " + explanation)
    elif column["nullable"] == "NO":
        notes.append("Không có DEFAULT: đường ghi phải cung cấp giá trị, trừ khi trigger được chỉ định gán trước INSERT.")
    # Chỉ identifier trong constraint mới tạo liên hệ; không nhầm tên cột nằm bên trong literal.
    for constraint in table.get("constraints") or []:
        definition = constraint["definition"]
        identifiers = {token[0].strip('"') for token in sql_tokens(definition) if re.fullmatch(r'"?[a-z_][a-z_0-9]*"?', token[0])}
        if name not in identifiers:
            continue
        kind = constraint["type"]
        if kind == "p":
            explanation = "khóa chính duy nhất và không NULL; nếu gồm nhiều cột thì uniqueness áp dụng cho cả tổ hợp."
        elif kind == "u":
            explanation = "không trùng tổ hợp giá trị được nêu; các cột riêng lẻ vẫn có thể lặp khi khóa có nhiều cột."
            if column["nullable"]=="YES":
                explanation += " UNIQUE mặc định không coi các giá trị NULL là trùng nhau."
        elif kind == "f":
            explanation = "khóa ngoại giữ đúng bản ghi cha; tổ hợp có workspace_id giữ quan hệ trong đúng tenant, không thay kiểm quyền hiện hành."
            if column["nullable"] == "YES":
                explanation += " FK MATCH SIMPLE mặc định bỏ kiểm khi có thành phần NULL; CHECK shape riêng vẫn phải đạt."
        else:
            explanation = "CHECK chỉ chặn khi biểu thức là FALSE; NULL/UNKNOWN vẫn qua, nên phải phối hợp NOT NULL và CHECK shape khi cần."
        notes.append("Ràng buộc hiện hành " + constraint["name"] + ": " + explanation)
        notes.append(definition)
    if table["name"] == "users" and name == "email_normalized":
        notes.append("CHECK length 3..254 chỉ kiểm số ký tự, không xác minh email RFC, số byte hoặc tự chuẩn hóa; backend phải validate và chuẩn hóa trước ghi.")
    if table["name"] == "users" and name == "activation_provenance":
        notes.append("CHECK btrim(...)<>'' chặn chuỗi rỗng/chỉ khoảng trắng; không tự giới hạn thành danh sách phương thức kích hoạt hay chứng minh đã kích hoạt.")
    return ["    -- " + part for note in notes for part in textwrap.wrap(note.replace("\n", " "), width=112)]


# Tách body CREATE TABLE theo comma cấp ngoài; comma trong CHECK, JSON hoặc FK không tách thuộc tính.
def annotate_tables(statement, manifest):
    """Thêm mô tả trước bảng/cột và tách một cột mỗi dòng mà không thay token executable.
    Input
    Param: statement — migration gốc hoặc pg_dump schema-only.
    Param: manifest — metadata hiện hành để mô tả ràng buộc của toàn bộ bảng.
    Output: source SQL có comment chi tiết; Errors: ValueError nếu gặp cột thiếu metadata.
    """
    tables = {table["name"]: table for table in manifest["tables"]}
    tables.update({table["name"]:dict(table,name="migration_control."+table["name"]) for table in manifest.get("internal_tables",[])})
    tokens = sql_tokens(statement)
    edits = []
    index = 0
    while index + 3 < len(tokens):
        if [tokens[index][0],tokens[index+1][0]] != ["CREATE","TABLE"]:
            index += 1
            continue
        name_index = index + 2
        if tokens[name_index+1][0] == ".":
            name_index += 2
        name = tokens[name_index][0].strip('"')
        if name not in tables or tokens[name_index+1][0] != "(":
            index += 1
            continue
        table = tables[name]
        columns = {column["name"]: column for column in table["columns"]}
        opening = name_index + 1
        depth = 1
        cursor = opening + 1
        segment_start = tokens[opening][2]
        segments = []
        while cursor < len(tokens) and depth:
            token, start, end = tokens[cursor]
            if token == "(":
                depth += 1
            elif token == ")":
                depth -= 1
            if (token == "," and depth == 1) or depth == 0:
                segments.append(statement[segment_start:start].strip())
                segment_start = end
            cursor += 1
        if depth:
            raise ValueError("Unterminated CREATE TABLE: " + name)
        rendered = []
        for segment in segments:
            field_tokens = sql_tokens(segment)
            if not field_tokens:
                continue
            first = field_tokens[0][0].strip('"')
            # Chỉ bỏ comment cũ trong body; token nguyên trạng giữ cả literal, operator và constraint.
            executable = segment[field_tokens[0][1]:].strip()
            if first in columns:
                rendered.extend(column_comments(table,columns[first]))
            else:
                rendered.append("    -- Ràng buộc cấp bảng: kiểm quan hệ giữa các thuộc tính; mô tả ở từng cột dùng metadata hiện hành.")
            rendered.append("    " + executable)
            rendered[-1] += ","
            rendered.append("")
        if rendered:
            rendered[-2] = rendered[-2][:-1]
        purpose = documentation.TABLE_DESCRIPTIONS[table["name"]]
        header = "\n".join("-- " + part for part in textwrap.wrap("Bảng " + table["name"] + ": " + purpose,width=112)) + "\n"
        edits.append((tokens[index][1],tokens[index][1],header))
        edits.append((tokens[opening][2],tokens[cursor-1][1],"\n" + "\n".join(rendered)))
        index = cursor
    for start,end,replacement in reversed(edits):
        statement = statement[:start] + replacement + statement[end:]
    return statement


# Archive ghi đúng byte gốc trước sửa comment; mỗi archive phải khớp SHA của evidence đã áp.
def main():
    """Sinh bản source có chú thích và snapshot dễ đọc; không kết nối DB hoặc sửa ledger.
    Side effects: lưu immutable archive cho 0001..0006, ghi source tương đương token SQL.
    Errors: RuntimeError nếu source có logic drift; không ghi đè archive hiện hữu.
    """
    manifest = json.loads((DIRECTORY / "manifest.json").read_text(encoding="utf-8"))
    evidence = json.loads((ROOT / "ops/database/evidence/platform-latest.json").read_text(encoding="utf-8"))
    ARCHIVE.mkdir(exist_ok=True)
    coverage = {}
    for path in sorted(DIRECTORY.glob("000[1-6]_*.sql")):
        archived = ARCHIVE / path.name
        if not archived.exists():
            original = path.read_bytes()
            if hashlib.sha256(original).hexdigest() != evidence["migrations"][path.name]["sha256"]:
                raise RuntimeError("Source differs from applied evidence: " + path.name)
            archived.write_bytes(original)
        else:
            executable_source(path)
        original = archived.read_text(encoding="utf-8")
        rendered = "/* Bản chú thích để đọc: ràng buộc hiện hành lấy từ manifest sau mọi forward migration.\n * Runner thực thi byte bất biến trong applied_sql và so token SQL với bản này; không sửa ledger.\n */\n" + annotate_tables(original,manifest)
        if [token[0] for token in sql_tokens(original)] != [token[0] for token in sql_tokens(rendered)]:
            raise RuntimeError("Comment generation changed SQL tokens: " + path.name)
        path.write_text(rendered,encoding="utf-8",newline="\n")
        coverage[path.name] = len(re.findall(r"^CREATE TABLE ",rendered,re.MULTILINE))
    print(json.dumps(coverage,indent=2))


if __name__ == "__main__":
    main()
