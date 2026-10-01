# tfs

An experimental deduplicating archiver that organizes files into a binary Merkle tree.

Instead of splitting data by fixed block sizes, it uses a rolling hash (FastCDC) to find content boundaries. When bytes are inserted or deleted, only the edited chunks change, so the rest of the file still matches and deduplicates.

---

## Properties

- **Shift-tolerant**: Inserting or deleting bytes does not break deduplication downstream.
- **Tree-level reuse**: Identical chunk sequences share internal tree nodes, not just raw byte payloads.
- **Direct seeks**: Reads arbitrary byte offsets in $O(log N)$ time using node weights, without linear scanning.
- **Streaming**: Pipes to and from `stdin` and `stdout`.
- **Limitation**: Chunks are stored uncompressed; space savings come purely from deduplication.

---

## Build

Requires Zig 0.16.0+.

```bash
zig build --release=fast
```

The binary will be in `zig-out/bin/tfs` (`tfs.exe` on Windows).

---

## Usage

### Example

```bash
# Store a file
tfs encode bundle.tfs data_v1.tar

# Store an updated version (shares matching chunks with v1)
tfs encode bundle.tfs data_v2.tar

# Pipe into an archive
cat dump.sql | tfs encode bundle.tfs - --name dump.sql

# View contents
tfs list bundle.tfs

# Extract
tfs decode bundle.tfs data_v1.tar
tfs decode bundle.tfs data_v2.tar custom_name.tar
tfs decode bundle.tfs dump.sql - | head -n 5
```

### Reference

```text
Usage:
  tfs encode <archive> [input|-]    [--name <entry_name>]
  tfs decode <archive> <entry_name> [output|-]
  tfs list   <archive>
```
