#!/usr/bin/env python3
"""
KernelSU v0.9.5 -- non-GKI (4.14) manual hooks patcher

Target: Xiaomi Redmi K30 Ultra (cezanne) / kernel 4.14.186
Usage : python3 scripts/patch_ksu_manual.py <kernel-source-dir>

Why a script instead of a .patch file:
  every insertion point sits inside a function body, where diff context lines
  are brittle. A unique anchor string + exact replacement is far more robust,
  and the script is idempotent. Each anchor must occur exactly once.
"""
import sys
import os

MARKER = "KernelSU manual hook"

# (file, anchor, replacement, description)
EDITS = [
    (
        "fs/exec.c",
        "\tint retval;\n"
        "\n"
        "\tif (IS_ERR(filename))\n",
        "\tint retval;\n"
        "\n"
        "#ifdef CONFIG_KSU\n"
        "\t/* KernelSU manual hook: execveat */\n"
        "\textern bool ksu_execveat_hook __read_mostly;\n"
        "\textern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t\t       void *argv, void *envp, int *flags);\n"
        "\textern int ksu_handle_execveat_sucompat(int *fd,\n"
        "\t\t\t\t\t\tstruct filename **filename_ptr,\n"
        "\t\t\t\t\t\tvoid *argv, void *envp,\n"
        "\t\t\t\t\t\tint *flags);\n"
        "\tif (unlikely(ksu_execveat_hook))\n"
        "\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
        "\telse\n"
        "\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp,\n"
        "\t\t\t\t\t     &flags);\n"
        "#endif\n"
        "\n"
        "\tif (IS_ERR(filename))\n",
        "execve/su hook",
    ),
    (
        "fs/open.c",
        "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n"
        "\n"
        "\tif (mode & ~S_IRWXO)",
        "\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n"
        "\n"
        "#ifdef CONFIG_KSU\n"
        "\t/* KernelSU manual hook: faccessat */\n"
        "\textern int ksu_handle_faccessat(int *dfd,\n"
        "\t\t\t\t\tconst char __user **filename_user,\n"
        "\t\t\t\t\tint *mode, int *flags);\n"
        "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
        "#endif\n"
        "\n"
        "\tif (mode & ~S_IRWXO)",
        "faccessat hook",
    ),
    (
        "fs/read_write.c",
        "\tssize_t ret;\n"
        "\n"
        "\tif (!(file->f_mode & FMODE_READ))\n",
        "\tssize_t ret;\n"
        "\n"
        "#ifdef CONFIG_KSU\n"
        "\t/* KernelSU manual hook: vfs_read */\n"
        "\textern bool ksu_vfs_read_hook __read_mostly;\n"
        "\textern int ksu_handle_vfs_read(struct file **file_ptr,\n"
        "\t\t\t\t       char __user **buf_ptr,\n"
        "\t\t\t\t       size_t *count_ptr, loff_t **pos);\n"
        "\tif (unlikely(ksu_vfs_read_hook))\n"
        "\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);\n"
        "#endif\n"
        "\n"
        "\tif (!(file->f_mode & FMODE_READ))\n",
        "vfs_read hook",
    ),
    (
        "fs/stat.c",
        "\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n"
        "\n"
        "\tif ((flags & ~(AT_SYMLINK_NOFOLLOW",
        "\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n"
        "\n"
        "#ifdef CONFIG_KSU\n"
        "\t/* KernelSU manual hook: vfs_statx */\n"
        "\textern int ksu_handle_stat(int *dfd,\n"
        "\t\t\t\t   const char __user **filename_user,\n"
        "\t\t\t\t   int *flags);\n"
        "\tksu_handle_stat(&dfd, &filename, &flags);\n"
        "#endif\n"
        "\n"
        "\tif ((flags & ~(AT_SYMLINK_NOFOLLOW",
        "vfs_statx hook",
    ),
    (
        "drivers/input/input.c",
        "\tint disposition = input_get_disposition(dev, type, code, &value);\n"
        "\n"
        "\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n",
        "\tint disposition = input_get_disposition(dev, type, code, &value);\n"
        "\n"
        "#ifdef CONFIG_KSU\n"
        "\t/* KernelSU manual hook: input event (safe mode key) */\n"
        "\textern bool ksu_input_hook __read_mostly;\n"
        "\textern int ksu_handle_input_handle_event(unsigned int *type,\n"
        "\t\t\t\t\t\t unsigned int *code, int *value);\n"
        "\tif (unlikely(ksu_input_hook))\n"
        "\t\tksu_handle_input_handle_event(&type, &code, &value);\n"
        "#endif\n"
        "\n"
        "\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n",
        "input event hook (safe mode)",
    ),
    (
        "fs/devpts/inode.c",
        "void *devpts_get_priv(struct dentry *dentry)\n"
        "{\n"
        "\tif (dentry->d_sb->s_magic != DEVPTS_SUPER_MAGIC)\n",
        "void *devpts_get_priv(struct dentry *dentry)\n"
        "{\n"
        "#ifdef CONFIG_KSU\n"
        "\t/* KernelSU manual hook: devpts (fixes pm in terminal) */\n"
        "\textern int ksu_handle_devpts(struct inode *);\n"
        "\tksu_handle_devpts(dentry->d_inode);\n"
        "#endif\n"
        "\tif (dentry->d_sb->s_magic != DEVPTS_SUPER_MAGIC)\n",
        "devpts hook",
    ),
]


def main():
    if len(sys.argv) != 2:
        print("usage: patch_ksu_manual.py <kernel-source-dir>", file=sys.stderr)
        return 2
    root = os.path.abspath(sys.argv[1])
    if not os.path.isfile(os.path.join(root, "Makefile")):
        print("error: %s does not look like a kernel tree" % root, file=sys.stderr)
        return 2

    changed = skipped = 0
    for rel, anchor, repl, desc in EDITS:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            print("error: missing %s" % rel, file=sys.stderr)
            return 1
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()

        if MARKER in text:
            print("  skip (already patched): %-22s %s" % (rel, desc))
            skipped += 1
            continue

        n = text.count(anchor)
        if n != 1:
            print(
                "error: anchor found %d times in %s (expected 1); "
                "source tree does not match this device/kernel version" % (n, rel),
                file=sys.stderr,
            )
            return 1

        text = text.replace(anchor, repl, 1)
        with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write(text)
        print("  patched: %-22s %s" % (rel, desc))
        changed += 1

    print("done: %d file(s) modified, %d skipped" % (changed, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
