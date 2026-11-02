#!/bin/sh
# ---------------------------------------------------------------------------
# Redmi K30 Ultra (cezanne) 4.14.186 内核构建脚本
#   目标：开启 LXC 所需 namespaces/cgroups + 集成 KernelSU v0.9.5
#
# 环境变量（都有默认值，CI 与本地 Linux 通用）：
#   KERNEL_DIR   内核源码目录           默认 ./kernel
#   OUT          编译输出目录           默认 ./out
#   KSU_DIR      KernelSU 源码目录      默认 ./KernelSU
#   CLANG_DIR    clang-r383902 目录     默认 ./toolchain/clang
#   GCC64_DIR    aarch64 GCC 4.9 目录   默认 ./toolchain/gcc64
#   KSU_MODE     kprobe | manual        默认 kprobe
#   LOCALVERSION 内核版本后缀（含前导 -）默认 空 => 4.14.186
#   JOBS         并行度                 默认 nproc
# ---------------------------------------------------------------------------
set -eu

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")/.." && pwd)

KERNEL_DIR=${KERNEL_DIR:-$HERE/kernel}
OUT=${OUT:-$HERE/out}
KSU_DIR=${KSU_DIR:-$HERE/KernelSU}
CLANG_DIR=${CLANG_DIR:-$HERE/toolchain/clang}
GCC64_DIR=${GCC64_DIR:-$HERE/toolchain/gcc64}
KSU_MODE=${KSU_MODE:-kprobe}
LOCALVERSION=${LOCALVERSION:-}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
DEFCONFIG=cezanne_user_defconfig
FRAGMENT=$HERE/configs/lxc-ksu.fragment

KERNEL_DIR=$(cd "$KERNEL_DIR" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

[ -f "$KERNEL_DIR/Makefile" ]        || die "找不到内核源码: $KERNEL_DIR"
[ -f "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" ] || die "找不到 $DEFCONFIG"
[ -x "$CLANG_DIR/bin/clang" ]        || die "找不到 clang: $CLANG_DIR/bin/clang"
[ -x "$GCC64_DIR/bin/aarch64-linux-android-gcc" ] || die "找不到 GCC 4.9: $GCC64_DIR"

export PATH="$CLANG_DIR/bin:$GCC64_DIR/bin:$PATH"

# 4.14 + LTO_CLANG/CFI_CLANG 必须用 lld 与 llvm 工具链，和官方 build.config.mtk.aarch64 一致
MAKE_VARS="ARCH=arm64 O=$OUT CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf AR=llvm-ar STRIP=llvm-strip"

log "内核版本: $(sed -n 's/^\(VERSION\|PATCHLEVEL\|SUBLEVEL\) *= *//p' "$KERNEL_DIR/Makefile" | paste -sd. -)"
log "clang: $("$CLANG_DIR/bin/clang" --version | head -n1)"
log "GCC  : $("$GCC64_DIR/bin/aarch64-linux-android-gcc" --version | head -n1)"
log "模式 : KSU_MODE=$KSU_MODE  LOCALVERSION='${LOCALVERSION}'  JOBS=$JOBS"

# ---------------------------------------------------------------------------
# 1. 把 KernelSU 接进内核树
# ---------------------------------------------------------------------------
integrate_kernelsu() {
	[ -d "$KSU_DIR/kernel" ] || die "找不到 KernelSU 源码: $KSU_DIR/kernel"

	log "集成 KernelSU 到 drivers/kernelsu"
	rm -rf "$KERNEL_DIR/drivers/kernelsu"
	cp -a "$KSU_DIR/kernel" "$KERNEL_DIR/drivers/kernelsu"

	if ! grep -q 'CONFIG_KSU' "$KERNEL_DIR/drivers/Makefile"; then
		printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
	fi
	if ! grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig"; then
		printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL_DIR/drivers/Kconfig"
	fi

	# 源码被复制进内核树后，KernelSU/Makefile 找不到 .git，会退回 KSU_VERSION=16，
	# 管理器会认为内核太旧。这里按上游公式 (10000 + commit 数 + 200) 显式固定。
	if [ -d "$KSU_DIR/.git" ]; then
		n=$(git -C "$KSU_DIR" rev-list --count HEAD 2>/dev/null || true)
		if [ -n "$n" ]; then
			v=$((10000 + n + 200))
			sed -i "s/-DKSU_VERSION=16/-DKSU_VERSION=$v/" "$KERNEL_DIR/drivers/kernelsu/Makefile"
			log "KernelSU 版本号固定为 $v（commit 数 $n）"
		fi
	else
		warn "KernelSU 不是 git 仓库，版本号将退回 16"
	fi
}

# ---------------------------------------------------------------------------
# 2. 应用 manual hooks 补丁（可选）
# ---------------------------------------------------------------------------
apply_manual_patches() {
	[ "$KSU_MODE" = manual ] || return 0
	log "应用 KernelSU manual hooks 补丁"
	python3 "$HERE/scripts/patch_ksu_manual.py" "$KERNEL_DIR" || die "manual hooks 打补丁失败"
}

# ---------------------------------------------------------------------------
# 3. 生成 .config
# ---------------------------------------------------------------------------
apply_config() {
	log "生成 $DEFCONFIG"
	make -C "$KERNEL_DIR" $MAKE_VARS "$DEFCONFIG" >/dev/null

	cfg="$OUT/.config"
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in ''|'#'*) continue ;; esac
		sym=${line%%=*}
		val=${line#*=}
		sym=${sym#CONFIG_}
		case "$val" in
			y) "$KERNEL_DIR/scripts/config" --file "$cfg" -e "$sym" ;;
			n) "$KERNEL_DIR/scripts/config" --file "$cfg" -d "$sym" ;;
			*) "$KERNEL_DIR/scripts/config" --file "$cfg" --set-str "$sym" "$(printf '%s' "$val" | tr -d '"')" ;;
		esac
	done < "$FRAGMENT"

	# 版本字符串：LOCALVERSION_AUTO 会拼上 -g<git sha>，导致厂商 .ko 的 vermagic 对不上
	if [ -n "$LOCALVERSION" ]; then
		log "版本后缀固定为: $LOCALVERSION"
		"$KERNEL_DIR/scripts/config" --file "$cfg" -d LOCALVERSION_AUTO
		"$KERNEL_DIR/scripts/config" --file "$cfg" --set-str LOCALVERSION "$LOCALVERSION"
	else
		"$KERNEL_DIR/scripts/config" --file "$cfg" -d LOCALVERSION_AUTO
		"$KERNEL_DIR/scripts/config" --file "$cfg" --set-str LOCALVERSION ""
	fi

	if [ "$KSU_MODE" = manual ]; then
		log "manual 模式：关闭 CONFIG_KPROBES，避免与手动 hook 重复触发"
		"$KERNEL_DIR/scripts/config" --file "$cfg" -d KPROBES
	fi

	make -C "$KERNEL_DIR" $MAKE_VARS olddefconfig >/dev/null
}

# ---------------------------------------------------------------------------
# 4. 回读校验：任何一项没生效就终止，避免白跑一小时
# ---------------------------------------------------------------------------
verify_config() {
	log "校验关键配置项"
	cfg="$OUT/.config"
	missing=""
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in ''|'#'*) continue ;; esac
		sym=${line%%=*}
		val=${line#*=}
		# manual 模式故意关掉 KPROBES，跳过这一条
		[ "$sym" = "CONFIG_KPROBES" ] && [ "$KSU_MODE" = "manual" ] && continue
		case "$val" in
			y) grep -qx "$sym=y" "$cfg" || missing="$missing $sym" ;;
			n) grep -qx "# $sym is not set" "$cfg" || missing="$missing $sym" ;;
		esac
	done < "$FRAGMENT"
	[ -z "$missing" ] || die "以下配置项没有生效，请检查依赖关系:$missing"

	if [ "$KSU_MODE" = kprobe ]; then
		grep -qx 'CONFIG_KPROBES=y' "$cfg" || die "KPROBES 未开启，kprobe 集成无法工作"
	fi
	grep -qx 'CONFIG_KSU=y' "$cfg" || die "CONFIG_KSU 未开启"
	log "配置校验通过"
}

# ---------------------------------------------------------------------------
# 5. 编译
# ---------------------------------------------------------------------------
build() {
	log "开始编译 Image.gz (并行 $JOBS)"
	make -C "$KERNEL_DIR" $MAKE_VARS -j"$JOBS" Image.gz
	[ -f "$OUT/arch/arm64/boot/Image.gz" ] || die "编译结束但找不到 Image.gz"
	log "编译完成: $OUT/arch/arm64/boot/Image.gz"

	# 官方 defconfig 打开了 CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE，
	# 说明开机用的 kernel 很可能是 Image.gz-dtb（内核+追加 mt6885.dtb）。
	# 这里额外构建一份；失败不致命，打包时会自动回退到 Image.gz。
	log "尝试构建 Image.gz-dtb（追加 mt6885.dtb）"
	if make -C "$KERNEL_DIR" $MAKE_VARS -j"$JOBS" Image.gz-dtb; then
		if [ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ]; then
			log "已生成: Image.gz-dtb"
		fi
	else
		warn "Image.gz-dtb 构建失败，将只使用 Image.gz"
	fi

	log "内核 release: $(cat "$OUT/include/config/kernel.release" 2>/dev/null || echo unknown)"
}

integrate_kernelsu
apply_manual_patches
apply_config
verify_config
build

log "全部完成"
