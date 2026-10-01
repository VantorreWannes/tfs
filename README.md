# tfs

A fast, content-deduplicating archive tool built on a binary Merkle tree.

---

## What It's Good At

- **Shift-proof deduplication**: Adding or deleting bytes in the middle of a file only affects that local segment. The rest of the file continues to deduplicate across revisions.
- **Hierarchical sharing**: Identical data is reused at both the chunk level and the tree level—entire identical subtrees share storage.
- **Instant seeks**: Reads any byte offset directly in $O(\log N)$ time without decompressing or streaming from the beginning.
- **Pipe-ready**: Ingests from `stdin` and streams to `stdout` seamlessly.

---

## Quickstart

### Build

```bash
zig build --release=fast
```

### Happy Path

```bash
# 1. Archive a file
tfs encode bundle.tfs data_v1.tar

# 2. Add an updated version (only modified data uses new space)
tfs encode bundle.tfs data_v2.tar

# 3. Ingest directly from a pipe
cat dump.sql | tfs encode bundle.tfs - --name dump.sql

# 4. List stored files
tfs list bundle.tfs

# 5. Extract files
tfs decode bundle.tfs data_v1.tar           # extracts to ./data_v1.tar
tfs decode bundle.tfs data_v2.tar custom.tar # extracts to ./custom.tar
tfs decode bundle.tfs dump.sql - | head -n 5 # streams to stdout
```

---

## CLI Reference

```text
Usage:
  tfs encode <archive> [input|-]    [--name <entry_name>]
  tfs decode <archive> <entry_name> [output|-]
  tfs list   <archive>
```
