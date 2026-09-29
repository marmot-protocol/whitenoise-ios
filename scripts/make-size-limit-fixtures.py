#!/usr/bin/env python3
import os
import sys

MIB = 1024 * 1024
ATTACHMENT_LIMIT = 50 * MIB
MESSAGE_LIMIT = 8000


def write_pdf(path, size):
    head = b"%PDF-1.4\n% White Noise size-limit fixture\n"
    tail = b"\n%%EOF\n"
    chunk = os.urandom(MIB)
    remaining = size - len(head) - len(tail)
    with open(path, "wb") as handle:
        handle.write(head)
        while remaining > 0:
            count = min(remaining, len(chunk))
            handle.write(chunk[:count])
            remaining -= count
        handle.write(tail)


def write_text(path, length):
    line = "The quick brown fox jumps over the lazy dog. "
    with open(path, "w") as handle:
        handle.write((line * (length // len(line) + 1))[:length])


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "size-limit-fixtures"
    os.makedirs(out, exist_ok=True)
    write_pdf(os.path.join(out, "over-limit-50MiB-plus-1-byte.pdf"), ATTACHMENT_LIMIT + 1)
    write_pdf(os.path.join(out, "at-limit-exactly-50MiB.pdf"), ATTACHMENT_LIMIT)
    write_pdf(os.path.join(out, "under-local-limit-45MiB.pdf"), 45 * MIB)
    write_text(os.path.join(out, "message-over-limit-8001-chars.txt"), MESSAGE_LIMIT + 1)
    write_text(os.path.join(out, "message-at-limit-8000-chars.txt"), MESSAGE_LIMIT)
    print(out)


if __name__ == "__main__":
    main()
