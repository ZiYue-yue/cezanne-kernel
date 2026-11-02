# Redmi K30 Ultra（cezanne）内核：LXC + KernelSU

给 **Redmi K30 Ultra（代号 cezanne，MT6889 / 天玑 1000+）** 定制 4.14 内核：
打开 LXC 所需的 namespace / cgroup / 网络能力，并集成 **KernelSU v0.9.5**。
面向 **MIUI 12.5.11（Android 11）**。

---

## 1. 已核实的事实

| 项目 | 值 |
|---|---|
| 设备 / 代号 | Redmi K30 Ultra / `cezanne` |
| SoC | 联发科 MT6889（天玑 1000+），平台名 `mt6885`，工程名 `k6889v1_64` |
| 系统 | MIUI 12.5.11（Android 11） |
| 内核版本 | **4.14.186**（`Makefile` 中 VERSION=4 PATCHLEVEL=14 SUBLEVEL=186） |
| 源码 | `MiCode/Xiaomi_Kernel_OpenSource` 分支 **`cezanne-r-oss`** |
| defconfig | `arch/arm64/configs/cezanne_user_defconfig` |
| 工具链 | AOSP **clang-r383902**（clang 11）+ **aarch64-linux-android-4.9** binutils |
| 关键编译特性 | `CONFIG_LTO_CLANG=y`、`CONFIG_CFI_CLANG=y` → 必须 `LD=ld.lld` + llvm 工具链 |
| KernelSU | **v0.9.5**（1.0 起官方不再支持非 GKI 内核，这是最后可用版本） |
| 产物 | 两个 AnyKernel3 卡刷包（`Image.gz-dtb` / `Image.gz`）+ 原始镜像 + 编译配置 |

> 本仓库只做「配置 + 集成 + 构建」，不修改设备分区，也不含任何闭源 blob。

---

## 2. 为什么在 GitHub Actions 上编译

内核必须在 Linux 下用 clang 交叉编译。当前这台 Windows 机器：没有 WSL、没有管理员权限、
命令行无法访问 GitHub（只有浏览器/受管通道能通），因此本地编译不可行。
GitHub Actions 的 Ubuntu runner 是零成本、可复现的替代方案：一次构建约 **40–90 分钟**，
公开仓库不消耗额度，私有仓库会消耗 Actions 分钟数（每月 2000 分钟免费额度）。

如果你有自己的 Linux 机器，本仓库同样可以直接用：

```sh
# 在一台 x86_64 Linux 上（需要 ~40 GB 空闲磁盘、git、python3）
sudo apt install -y bc bison build-essential flex libelf-dev libssl-dev lz4 lzop zip cpio
git clone --depth=1 -b cezanne-r-oss https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git kernel
rm -rf kernel/.git
git clone --filter=blob:none https://github.com/tiann/KernelSU.git KernelSU && git -C KernelSU checkout v0.9.5
# 按 workflow 里的两条 curl 命令下载 clang-r383902 与 GCC 4.9 到 toolchain/{clang,gcc64}
KSU_MODE=kprobe sh scripts/build.sh
```

---

## 3. 快速开始（5 步）

### 3.1 建仓库并上传

在 GitHub 新建一个仓库（Public 更快且不消耗额度，Private 也可以），然后在本目录执行：

```sh
git init
git add .
git commit -m "cezanne 4.14.186: LXC + KernelSU"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> 若 `git push` 因为网络失败，用浏览器「上传文件」把整个目录拖进去也可以（必须保留
> `.github/workflows/build.yml` 的目录结构，否则 Actions 里不会出现这个 workflow）。

### 3.2 运行构建

仓库页面 → **Actions** → 左侧 **Build cezanne kernel (LXC + KernelSU)** → **Run workflow**。

| 参数 | 首次建议值 | 说明 |
|---|---|---|
| `ksu_mode` | `kprobe` | KernelSU 集成方式。kprobe 改动最小、最可能一次成功；若刷完开不了机，再用 `manual` 重跑一次 |
| `localversion` | 留空 | 内核版本后缀。**要让厂商的 `.ko` 模块继续能加载，必须和官方 `uname -r` 完全一致**，见 3.4 |

点 **Run workflow** 后等 40–90 分钟（日志里能看到 `==> 开始编译 Image.gz` 与最终的
`内核 release: 4.14.186`）。

### 3.3 下载产物

构建完成后进入该次 run 页面，底部 **Artifacts** 下载 `cezanne-lxc-ksu-kprobe.zip`，解压得到：

| 文件 | 用途 |
|---|---|
| `cezanne-lxc-ksu-kprobe-dtb-anykernel3.zip` | **优先刷这个**：内核 + 追加 `mt6885.dtb`（官方 defconfig 打开了 `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE`） |
| `cezanne-lxc-ksu-kprobe-gz-anykernel3.zip` | 备选：纯 `Image.gz`。若上面的包开不了机再试这个 |
| `Image.gz` / `Image.gz-dtb` / `Image` | 原始内核镜像，手工重打包 boot.img 用 |
| `config.txt` | 本次编译最终生效的 `.config`，排错用 |
| `System.map` | 符号表，抓内核日志/调 kprobe 用 |
| `kernel-release.txt` | 本次内核的 release 字符串（等于 `uname -r`） |

Artifacts 默认保留 30 天。

### 3.4 关于 `localversion`（重要，先读再刷）

Android 的厂商内核模块（`/vendor/lib/modules/*.ko`）在加载时会校验 **vermagic**，
它包含内核 release 字符串。我们的内核是 `4.14.186`，如果官方内核是 `4.14.186-g1a2b3c4d`，
vermagic 不一致 → Wi-Fi / 蓝牙 / GPS / FM 等模块加载失败。

先在**官方系统**上读一下真实版本：

```sh
adb shell uname -r
# 例如输出: 4.14.186-g1a2b3c4d
```

把 `4.14.186` 之后的部分（**包含开头的 `-`**）填进 `localversion`，例如 `-g1a2b3c4d`，重新跑一次构建。
如果输出就是 `4.14.186`，留空即可。

---

## 4. 刷入前

1. **解锁 Bootloader**（小米社区申请 + Mi Unlock）。未解锁无法刷 boot。
2. **备份原厂 boot**（出问题唯一可靠的退路）：
   ```sh
   # 已有 root（Magisk/KernelSU）时：
   adb shell "su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot_stock.img'"
   adb pull /sdcard/boot_stock.img
   ```
   若没有 root：下载对应版本 **fastboot 线刷包**（`cezanne_images_V12.5.11.0.*.tgz`），
   解压后 `images/boot.img` 就是原厂 boot。
3. **确认系统版本是 12.5.11**。内核与 vendor/ramdisk 是配套的，跨大版本刷入容易卡开机。
4. 电量 > 50%，USB 调试可用。

---

## 5. 刷入

### 方式 A：TWRP（推荐）

1. 进 TWRP（K30 Ultra 有第三方 TWRP，`fastboot boot twrp.img` 临时启动也可以）。
2. **先备份** Boot 分区（TWRP → Backup → 勾选 Boot）。
3. 刷入 `cezanne-lxc-ksu-kprobe-dtb-anykernel3.zip`。
4. 重启。

### 方式 B：AIK 重打包 + fastboot

1. 用 [Android-Image-Kitchen](https://github.com/osm0sis/Android-Image-Kitchen) 解开原厂 `boot.img`。
2. 把 `split_img/boot.img-kernel` 替换成本仓库产物里的 `Image.gz-dtb`（或 `Image.gz`）。
3. `repackimg` 生成 `image-new.img`。
4. 刷入：
   ```sh
   adb reboot bootloader
   fastboot flash boot image-new.img
   fastboot reboot
   ```

> 小米解锁后刷入修改过的 boot 一般**不需要**动 vbmeta（会显示 unlocked 警告，属正常）。
> 如果确实卡在验证阶段，再执行：
> `fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img`
> （`vbmeta.img` 来自同版本线刷包，此操作会让 dm-verity 失效，请自行权衡）。

### 回滚

```sh
fastboot flash boot boot_stock.img
fastboot reboot
```

---

## 6. 验证

```sh
adb shell uname -r                 # 应显示 4.14.186 或你指定的 localversion
adb shell "su -c 'ls /proc/self/ns'"   # 应看到 cgroup ipc mnt net pid user uts
adb shell "su -c 'zcat /proc/config.gz | grep -E \"CONFIG_(KSU|USER_NS|MEMCG|CGROUP_DEVICE|OVERLAY_FS)=\"'"
adb shell "su -c 'dmesg | grep -i kernelsu'"   # 应看到 KernelSU 初始化日志
```

- **KernelSU**：安装 [KernelSU v0.9.5 管理器 APK](https://github.com/tiann/KernelSU/releases/tag/v0.9.5)，
  打开后应显示「已安装 / 工作中」，并能授权 root。
- **LXC**：在 root shell 里跑 `lxc-checkconfig`，`Namespaces`、`Cgroup device`、
  `Cgroup memory controller` 等应全部为 `enabled`。

---

## 7. 使用 LXC

Android 上没有 systemd，`lxc-*` 命令需要自备（Debian rootfs 里自带，或 Termux 装 `lxc` 静态包）。
下面是最小可用流程，全部在 **root shell** 里执行。

### 7.1 关掉 SELinux 强制模式

MIUI 的 SELinux 策略不允许容器做 mount / mknod / setns：

```sh
su
setenforce 0
getenforce      # 应为 Permissive
```

重启会恢复 Enforcing。要持久化，用 KernelSU 模块在 `service.sh` 里执行 `setenforce 0`
（late_start 阶段执行才有效，`post-fs-data.sh` 太早）。

### 7.2 挂载 cgroup v1

Android 默认只挂了部分控制器，且视图不完整。LXC 需要统一挂载点：

```sh
mount -t tmpfs cgroup_root /sys/fs/cgroup
for c in cpu cpuacct cpuset memory devices freezer pids; do
  mkdir -p /sys/fs/cgroup/$c
  mount -t cgroup -o $c cgroup /sys/fs/cgroup/$c
done
cat /proc/cgroups          # 各控制器 enabled 应为 1
```

### 7.3 准备 rootfs 并创建容器

```sh
mkdir -p /data/lxc/debian          # 放一个 Debian arm64 rootfs（debootstrap 产物）
lxc-create -n debian -t none -B dir --dir /data/lxc/debian
```

编辑 `/data/local/.../lxc/debian/config`（或 `lxc-create` 生成的 `~/.local/share/lxc/...`）：

```ini
lxc.uts.name = debian
lxc.rootfs.path = dir:/data/lxc/debian
lxc.mount.auto = proc:mixed sys:ro cgroup:mixed
# 先用无网络模式验证能否启动
lxc.net.0.type = none
```

启动：

```sh
lxc-start -n debian -F      # -F 前台运行，方便看报错
# 另开一个 shell：
lxc-attach -n debian -- /bin/bash
```

### 7.4 需要联网时

```sh
ip link add lxcbr0 type bridge
ip addr add 10.0.3.1/24 dev lxcbr0
ip link set lxcbr0 up
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 10.0.3.0/24 -o wlan0 -j MASQUERADE
```

容器 config 里改成：

```ini
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.ipv4.address = 10.0.3.2/24
lxc.net.0.ipv4.gateway = 10.0.3.1
```

> 注意：Android 的 `netd` 也会操作 iptables。折腾容器网络后如果手机自身网络异常，
> 重启即可恢复（这些规则不会持久化）。

---

## 8. 改配置 / 换版本

所有内核选项集中在 **`configs/lxc-ksu.fragment`**，语法就是 `CONFIG_FOO=y/n/"str"`。
`scripts/build.sh` 会逐条写进 `.config`、跑 `olddefconfig`、再逐条回读校验——
**任何一条没生效都会让构建直接失败并打印缺失清单**，不会让你白等一小时才发现问题。

比如想关掉 `MEMCG`（内存控制器会增加一点开销，也是本方案里对系统内存行为影响最大的一项；
若刷完出现异常的内存回收/杀后台行为，可以把它设为 `n` 再编一次）：

```
CONFIG_MEMCG=n
```

想换成 manual hooks：本次 run 的 `ksu_mode` 选 `manual` 即可，脚本会：
1. 用 `scripts/patch_ksu_manual.py` 在 `fs/exec.c`、`fs/open.c`、`fs/read_write.c`、
   `fs/stat.c`、`drivers/input/input.c`、`fs/devpts/inode.c` 插入 hook（锚点用真实源码校验过，
   且幂等）；
2. 关掉 `CONFIG_KPROBES`，避免 kprobe 与手动 hook 重复触发、以及误触安全模式。

---

## 9. 常见问题

**Q：构建在「校验关键配置项」处失败，提示某个 `CONFIG_xxx` 没生效？**
通常是 Kconfig 依赖没满足（例如 `CONFIG_KSU` 依赖 `CONFIG_OVERLAY_FS`）。日志里会列出缺失项，
把它发我即可；也可以在 `configs/lxc-ksu.fragment` 里先手动补上被依赖的项。

**Q：编译报 `Image.gz-dtb` 失败？**
脚本里这一步是「尽力而为」：失败只告警，仍会产出 `Image.gz`。

**Q：刷完卡在开机第一屏 / 无限重启？**
1. 先确认刷的是 `-dtb-` 包；不行再换 `-gz-` 包（两种镜像格式，见 3.3）。
2. 都失败就 `fastboot flash boot boot_stock.img` 回滚，然后用 `ksu_mode=manual` 重编一次。
3. KernelSU 的安全模式：开机时按住音量下键可禁用模块（仅 kprobe 模式，manual 模式已关掉 kprobe）。

**Q：能开机，但 Wi-Fi / 蓝牙 / GPS 打不开？**
vermagic 不匹配导致 `/vendor/lib/modules/*.ko` 加载失败。按 3.4 读取官方 `uname -r`，
把后缀填进 `localversion` 重新编译。

**Q：KernelSU 管理器显示「未安装」？**
- 确认刷的是本仓库的包（不是原厂 boot）；
- 管理器必须是 **v0.9.5**（新版管理器不再支持非 GKI 内核）；
- `adb shell "su -c 'dmesg | grep -i ksu'"` 看内核侧有没有初始化日志。

**Q：容器起不来，报 `Failed to mount cgroup` / `Permission denied`？**
按顺序检查：`setenforce 0` → 7.2 的 cgroup 挂载 → 先用 `lxc.net.0.type = none` 排除网络因素。

**Q：可以 OTA 升级系统吗？**
不行。OTA 会覆盖 boot，需要重新刷入本内核；跨大版本（如 12.5.11 → 13）不能直接沿用。

---

## 10. 目录结构

```
k30ultra-kernel/
├─ .github/workflows/build.yml    # GitHub Actions：下载源码/工具链 → 编译 → 打包 → 上传
├─ anykernel/anykernel.sh         # AnyKernel3 配置（device=cezanne，BLOCK=boot，无 A/B）
├─ configs/lxc-ksu.fragment       # LXC + KernelSU 的全部内核配置项
├─ scripts/
│  ├─ build.sh                    # 构建主脚本（本地 Linux 与 CI 通用）
│  └─ patch_ksu_manual.py         # KernelSU manual hooks 补丁器（幂等、锚点校验）
└─ README.md
```

构建流程：

```
cezanne-r-oss 源码
   ├─ 复制 KernelSU/kernel → drivers/kernelsu，挂进 drivers/Makefile + Kconfig
   ├─ 合并 lxc-ksu.fragment → .config → olddefconfig → 逐项回读校验
   └─ make Image.gz / Image.gz-dtb（clang-r383902 + ld.lld + GCC 4.9）
        └─ AnyKernel3 打包 → 卡刷 zip
```

---

## 11. 许可与免责

- 内核源码来自小米开源（GPL-2.0），KernelSU 为 GPL-3.0，本仓库脚本同样以 GPL-2.0 发布。
- 刷机有变砖风险。请务必先备份 `boot`，并确认自己已解锁 Bootloader。
  因刷机导致的任何损失由操作者自行承担。
- 本项目与小米、KernelSU 官方无隶属关系。
