#!/usr/bin/env python3
"""Diagnose and undo moves recorded in a photo-sort manifest.csv.

By default this is a dry run: it explains, row by row, why each file can or
cannot be put back. Pass --apply to actually move files.

    python undo_manifest.py C:\\photo-sort\\Sorted\\manifest.csv
    python undo_manifest.py C:\\photo-sort\\Sorted\\manifest.csv --apply
"""
import argparse
import csv
import os
import shutil
import sys
from collections import Counter, defaultdict

SRC_NAMES = ["src", "source", "from", "orig", "original", "old", "old_path",
             "src_path", "source_path", "original_path", "input", "path"]
DST_NAMES = ["dst", "dest", "destination", "to", "new", "new_path", "target",
             "dst_path", "dest_path", "target_path", "output", "moved_to"]


def read_manifest(path):
    raw = open(path, "rb").read()
    for enc in ("utf-8-sig", "cp1251", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    sample = text[:8192]
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
    except csv.Error:
        dialect = csv.excel
    rows = list(csv.reader(text.splitlines(), dialect))
    return enc, dialect.delimiter, rows


def pick_column(header, names, override):
    if override is not None:
        return int(override) if str(override).isdigit() else \
            [h.strip().lower() for h in header].index(override.lower())
    norm = [h.strip().strip('"').lower() for h in header]
    for name in names:
        if name in norm:
            return norm.index(name)
    return None


def clean(p):
    return os.path.normpath(p.strip().strip('"').strip("'")) if p.strip() else ""


def resolve_pair(src, dst, base_dirs):
    """Relative paths: use the base folder where dst (or src) actually exists."""
    if (not src or os.path.isabs(src)) and (not dst or os.path.isabs(dst)):
        return src, dst
    for base in base_dirs:
        s, d = os.path.join(base, src), os.path.join(base, dst)
        if os.path.exists(d) or os.path.exists(s):
            return s, d
    return os.path.join(base_dirs[0], src), os.path.join(base_dirs[0], dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--apply", action="store_true", help="actually move files")
    ap.add_argument("--src-col", help="source column name or 0-based index")
    ap.add_argument("--dst-col", help="destination column name or 0-based index")
    ap.add_argument("--no-header", action="store_true")
    ap.add_argument("--search", action="store_true",
                    help="if dst is missing, look for the file by name under the manifest folder")
    args = ap.parse_args()

    enc, delim, rows = read_manifest(args.manifest)
    if not rows:
        sys.exit("Манифест пуст.")
    header = [] if args.no_header else rows[0]
    data = rows if args.no_header else rows[1:]

    print(f"Кодировка: {enc}, разделитель: {delim!r}, строк данных: {len(data)}")
    print(f"Заголовок: {header}")
    print(f"Первая строка: {data[0] if data else None}\n")

    si = pick_column(header, SRC_NAMES, args.src_col) if header else args.src_col
    di = pick_column(header, DST_NAMES, args.dst_col) if header else args.dst_col
    if si is None or di is None:
        sys.exit("Не удалось определить колонки источника/назначения. "
                 "Укажите --src-col и --dst-col (имя или номер с 0).")
    si, di = int(si), int(di)
    print(f"Источник = колонка {si} ({header[si] if header else '?'}), "
          f"назначение = колонка {di} ({header[di] if header else '?'})\n")

    mdir = os.path.dirname(os.path.abspath(args.manifest))
    bases = [os.getcwd(), os.path.dirname(mdir), mdir]

    by_name = None
    if args.search:
        by_name = defaultdict(list)
        for root, _, files in os.walk(mdir):
            for f in files:
                by_name[f.lower()].append(os.path.join(root, f))

    stats, examples = Counter(), defaultdict(list)

    def note(reason, row):
        stats[reason] += 1
        if len(examples[reason]) < 3:
            examples[reason].append(row)

    for row in data:
        if len(row) <= max(si, di):
            note("битая строка (мало колонок)", row)
            continue
        src, dst = resolve_pair(clean(row[si]), clean(row[di]), bases)
        if not src or not dst:
            note("пустой путь", row)
            continue
        if not os.path.exists(dst) and by_name is not None:
            hits = by_name.get(os.path.basename(dst).lower(), [])
            if len(hits) == 1:
                dst = hits[0]
        dst_ok, src_ok = os.path.isfile(dst), os.path.exists(src)
        if dst_ok and not src_ok:
            if args.apply:
                try:
                    os.makedirs(os.path.dirname(src), exist_ok=True)
                    shutil.move(dst, src)
                    note("возвращён", (dst, src))
                except OSError as e:
                    note(f"ошибка: {e.__class__.__name__}", (dst, src, str(e)))
            else:
                note("можно вернуть", (dst, src))
        elif dst_ok and src_ok:
            same = os.path.getsize(dst) == os.path.getsize(src)
            note("оба существуют, размер совпадает (было копирование?)" if same
                 else "оба существуют, размеры разные (конфликт)", (dst, src))
        elif src_ok:
            note("уже на месте (в Sorted нет)", (dst, src))
        else:
            note("нет ни там, ни там", (dst, src))

    print("Итог:")
    for reason, n in stats.most_common():
        print(f"  {n:6d}  {reason}")
        for ex in examples[reason]:
            print(f"          {ex}")
    if not args.apply and stats.get("можно вернуть"):
        print("\nЭто был пробный прогон. Для реального отката добавьте --apply.")


if __name__ == "__main__":
    main()
