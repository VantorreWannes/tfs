# tfs

An experimental deduplicating filesystem-in-a-file that stores content in a hash tree.

Content is split into fixed-size words (256 bytes). Each distinct word is stored once and referenced by hash; parent nodes store the hashes of their children, so identical word sequences share whole subtrees as well as raw words.

---

## Properties

- **Content-addressed**: identical words and identical word sequences are stored once.
- **Streaming**: pipes to and from `stdin` and `stdout`.
- **On-demand mounting**: mounts stores as virtual directories via Windows ProjFS, reading content dynamically without extracting it, and capturing modified files back into the store.
- **Limitation**: content is stored uncompressed; space savings come purely from deduplication. Files are limited to 1 GiB.

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
tfs put bundle.tfs data_v1.tar

tfs put bundle.tfs data_v2.tar

cat dump.sql | tfs put bundle.tfs -   # stdin input is stored under the name "-"

tfs ls bundle.tfs
tfs ls bundle.tfs docs

tfs get bundle.tfs data_v1.tar
tfs get bundle.tfs data_v2.tar custom_name.tar
tfs get bundle.tfs data_v1.tar - | head -n 5

tfs mount bundle.tfs ./mnt
```

### Reference

```text
usage:
  tfs put <store> <file>          store a file into the filesystem
  tfs get <store> <path> [out]    extract a file (out "-" = stdout)
  tfs ls <store> [path]           list a directory
  tfs mount <store> <dir>         mount as a virtual directory (Windows ProjFS)

  <store>  data file; index kept beside it as <store>.idx,
           namespace snapshot as <store>.ns
  <path>   path inside the filesystem, e.g. docs/notes/a.txt
```

### Mounting

`mount` projects the store into a local directory via Windows ProjFS. Files are
hydrated on demand, and files modified through the mount are captured back into
the store while it is mounted.

On unmount (Ctrl+C), pending captures are drained and committed before cleanup.
Cleanup visits only paths in the committed namespace: clean ProjFS placeholders
and files verified byte-for-byte against the store are removed, followed by
empty known directories. The mount root itself remains.

Unknown paths, changed or busy files, read-only files, links/junctions, and files
with alternate data streams are retained. If capture or commit fails, cleanup is
skipped. The command reports incomplete cleanup rather than silently deleting
unverified data; verify retained files before removing them manually.
