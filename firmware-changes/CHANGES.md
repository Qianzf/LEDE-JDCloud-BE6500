# 改动清单（症状 → 根因 → 修复 → 证据）

固件：JDCloud BE6500 / RE-CS-06，OpenWrt 24.10.5 r8302-e5dc1a534，内核 6.18.62
基线：coolsnowwolf/lede `e5dc1a534`

一共 **6 处源码/配置改动** + **3 处构建环境处理**。前 5 项是补丁文件，第 6 项是 `.config` 改动。

| # | 问题 | 类型 | 影响 |
|---|---|---|---|
| 1 | WiFi 无信号（BDF 打包缺失） | 源码补丁 | 致命 |
| 2 | 国家码默认 US | 源码补丁 | 功能 |
| 3 | 802.11k 默认关 | 源码补丁 | 功能 |
| 4 | `gettext-full` 补丁冲突 | 源码回退 | 阻断构建 |
| 5 | `backports 7.2` 在 6.18.62 上编译失败 | 新增补丁 | 阻断构建 |
| 6 | 内核 FIT 超出 7MiB 分区 | `.config` | 阻断出镜像 |
| A | host `cond.m4` 被 gnulib 覆盖 | 构建环境 | 阻断构建 |
| B | Rust/LLVM 依赖链过长 | `.config` 取舍 | 时间 |
| C | 默认中文 UI / 主题 / 主机名 | overlay 文件 | 功能 |

---

## 1. WiFi 无信号：`ipq-wifi` 的 BDF 没被打进固件

**补丁**：`patches/0001-ipq-wifi-install-local-bdf.patch`
**文件**：`package/firmware/ipq-wifi/Makefile`

### 症状

刷好固件后 LuCI 里能看到无线配置，但设备搜不到任何 SSID；`iwinfo` 显示 radio 存在却没有信号。

### 根因

`package/firmware/ipq-wifi/Makefile` 的 `install-overlay` 只从上游 git 仓库的产物里拷贝：

```make
$(INSTALL_DIR) $(1)/lib/firmware/ath12k/...
$(CP) $(PKG_BUILD_DIR)/board-$(1).* ...
```

而该 Makefile 锁定的上游提交 `49ce14c099b16044b7062df54bdabeb495b804ad`
（`https://git.openwrt.org/project/firmware/qca-wireless.git`）**根本没有**
`board-jdcloud_re-cs-06.*` 这两个文件（全库 164 个文件，只有 `re-cs-02` 和 `re-ss-01`）。

结果是该包安装出**空目录** → 内核回退使用 `ath-firmware-ddwrt` 里的通用 dd-wrt
评估板 `board-2.bin` → 该文件的 `qmi-board-id` 与 DTS 里的 `qcom,board-id` 不匹配
→ ath12k 初始化失败 → **无信号**。

同时源码树里其实**已经存在正确的 BDF 文件**，只是没人引用：

```
package/firmware/ipq-wifi/files/board-jdcloud_re-cs-06.ipq5332   89,292 B  bus=ahb,qmi-chip-id=0,qmi-board-id=22
package/firmware/ipq-wifi/files/board-jdcloud_re-cs-06.qcn9274  126,148 B  bus=pci,qmi-chip-id=0,qmi-board-id=2
```

（`files/` 目录下还有 gl-be9300、be10000、be7000 等 7 个同平台 BDF，全部是孤儿文件。）

### 修复

在该 Makefile 中加入 `Build/Prepare`，把本地 `files/` 合并进 `PKG_BUILD_DIR`，
让原有的 `install-overlay` 通配符 `board-$(1).*` 能命中：

```make
define Build/Prepare
	$(call Build/Prepare/Default)
	$(if $(wildcard $(CURDIR)/files),$(CP) -a $(CURDIR)/files/. $(PKG_BUILD_DIR)/,)
endef
```

用 `$(if $(wildcard ...))` 保证：`files/` 不存在时展开为空命令，不影响其他平台。

### 证据

编译后检查安装产物（不是源码，是真正进 ipk 的文件）：

```
.../ipkg-aarch64_cortex-a53/ipq-wifi-jdcloud_re-cs-06/rootfs-overlay/lib/firmware/ath12k/
    IPQ5332/hw1.0/board-2.bin   sha256 2c35e553b52b6d78...  qmi-board-id=22   ← 与源码一致
    QCN9274/hw2.0/board-2.bin   sha256 94dbe473bbeac5f8...  qmi-board-id=2    ← 与源码一致
```

最终镜像内的验证（`root-qualcommbe/lib/firmware/...`）同样为 89,292 B / `qmi-board-id=22`
和 126,148 B / `qmi-board-id=2`，与 DTS 的 `qcom,board-id = <22>` / `<2>` 完全对应。

---

## 2. 国家码默认 US → CN

**补丁**：`patches/0002-mac80211-default-country-cn.patch`
**文件**：`package/kernel/mac80211/files/lib/wifi/mac80211.sh:355`

### 根因

生成 `/etc/config/wireless` 时，如果 `/etc/board.json` 里没有
`wlan.defaults.country`，就回退到硬编码的 `US`：

```sh
[ -n "$country" ] || country="US"
```

board.json 由 `board.d` 脚本生成，本目标没有提供国家码，所以所有机器默认 US。
US 的 5G 可用信道与功率限制都与中国不同（缺 149-165 的部分组合限制、DFS 规则不同）。

### 修复

```diff
-	[ -n "$country" ] || country="US"
+	[ -n "$country" ] || country="CN"
```

选择改这里的理由：这是**生成配置那一刻**生效的点，比 uci-defaults 更可靠
（uci-defaults 在 wifi 配置已生成之后才跑，时序上依赖 `30_wifi` 是否已执行）。

### 证据

镜像内 `root-qualcommbe/lib/wifi/mac80211.sh:355` 为 `country="CN"`。

---

## 3. 802.11k 默认开启（802.11r 保持关闭）

**补丁**：`patches/0003-hostapd-default-80211k-on.patch`
**文件**：`package/network/services/hostapd/files/hostapd.sh:873`

### 理由

- **802.11k**（无线资源测量）：纯被动上报，客户端可选支持，不支持也无副作用 → 默认开
- **802.11r**（快速漫游）：需要客户端配合；单 AP 部署下反而可能造成握手问题 → 保持默认关

### 修复

```diff
-	set_default ieee80211k 0
+	set_default ieee80211k 1
```

### 证据

镜像内 `root-qualcommbe/lib/netifd/hostapd.sh:873` 为 `set_default ieee80211k 1`。

---

## 4. `gettext-full`：gnulib 补丁无法应用（阻断构建）

**补丁**：`patches/0004-gettext-full-bump-to-0.24.2.patch`
**文件**：`package/libs/gettext-full/{Makefile,patches/200-libunistring-missing-link.patch}`

### 症状

```
gnulib-tool: *** patch file lib/exitfail.h didn't apply cleanly
```

### 根因

该 fork 的 `tools/gnulib` 是 **2026.07.04（stable-202507）**，而
`package/libs/gettext-full` 停留在 **0.22.5**。上游 OpenWrt master 使用的是
**gettext 0.24.2 + gnulib b22f5a30（同为 stable-202507）** 的匹配组合。
版本错配导致 gnulib-tool 应用自家补丁时上下文不匹配。

### 修复

```bash
git checkout 5ba7ce24d -- package/libs/gettext-full     # → 0.24.2，PKG_HASH fcc0187f...
```

即把该包整体对齐到上游 master 的版本。

### 证据

修复前：`patch 失败数 > 0`，构建中断。
修复后：`patch 失败数 0`，gettext 0.24.2 在 22:07 编译完成，
其 host 部分继续满足 `feeds/packages/libs/gnutls/Makefile:22` 的
`PKG_BUILD_DEPENDS:=gettext-full/host` 硬依赖。

> 注意：这个包在 staging 里留下过副作用，见「附录 A」。

---

## 5. `backports 7.2` 在内核 6.18.62 上编译失败（阻断构建）

**补丁**：`patches/0005-backports-sockaddr-unsized.patch`
**落点**：`package/kernel/mac80211/patches-qualcommbe/build/503-backport-declare-sockaddr-unsized.patch`

### 症状

```
drivers/net/wireless/ath/ath12k/qmi.c:4382:45: error: passing argument 2 of
'backport_kernel_connect' from incompatible pointer type [-Werror=incompatible-pointer-types]
```

### 根因（两层）

**第一层**：`backports-7.2/backport-include/linux/net.h` 里

```c
#if LINUX_VERSION_IS_LESS(6,19,0)
static inline int backport_kernel_connect(struct socket *sock,
                                          struct sockaddr_unsized *addr, ...)
```

但 `struct sockaddr_unsized` 是内核 **6.19** 才引入的类型。

**第二层**（关键）：`patches-qualcommbe/build/160-backports-sockaddr_unsized-is-in-6.18.57.patch`
把这处保护条件改成了 `LINUX_VERSION_IS_LESS(6,18,57)`，理由是「6.18.57 起内核自带该类型」，
于是 backports 在 6.18.62 上**不再定义**这个结构体。但实测本仓库的 6.18.62 内核
**并没有**该类型：

```
$ grep -rn "sockaddr_unsized" include/linux/socket.h net/socket.c include/net/
（零命中）
```

于是类型不存在 → 隐式声明 → 与 ath12k 里的显式转换类型不一致 → `-Werror` 报错。

### 修复

在 compat 头文件的同一分支里补一个前向声明（只需要指针，无需完整定义）：

```c
#if LINUX_VERSION_IS_LESS(6,19,0)
/* Kernels older than 6.19 do not define struct sockaddr_unsized at all,
 * forward declare it so drivers using the newer API still compile. */
struct sockaddr_unsized;
static inline int backport_kernel_connect(...)
```

### ⚠️ 补丁必须放对目录

`package/kernel/mac80211/Makefile:13-19` 有分支：

```make
ifeq ($(CONFIG_TARGET_qualcommbe),y)
PKG_VERSION:=7.2
PATCH_DIR:=./patches-qualcommbe     # ← qualcommbe 只读这个目录
else
PATCH_DIR:=./patches                # ← 其他目标
```

最初补丁放在 `patches/build/`，**对 qualcommbe 目标完全无效**（编译产物里没有该声明，
错误照旧）。必须放 `patches-qualcommbe/build/`。

### 验证方法（不依赖整包编译）

把 `dl/backports-7.2.tar.zst` 解包，按序应用 `patches-qualcommbe/build/*.patch`：

```
OK  000-fix_kconfig.patch
...
OK  160-backports-sockaddr_unsized-is-in-6.18.57.patch
...
OK  503-backport-declare-sockaddr-unsized.patch     ← 本次新增，零 fuzz
结果：backport-include/linux/net.h:15   struct sockaddr_unsized;
```

### 证据

```
drivers/net/wireless/ath/ath12k/qmi.o            ✅ 生成（原报错文件）
ath12k 目录 47 个 .o                              ✅
mac80211 目录 21 个 .ko（含 ath12k.ko/mac80211.ko）✅
```

---

## 6. 内核 FIT 超出 7MiB 分区（阻断出镜像）

**类型**：`.config` 改动（无源码补丁）

### 症状

编译到最后一步、包全部成功之后，镜像生成失败：

```
WARNING: Image file .../jdcloud_re-cs-06-uImage.itb is too big: 8276672 > 7340032
make[5]: *** [...-squashfs-factory.bin] Error 1
```

`include/image-commands.mk:212` 的 `Build/check-size` **不是只警告，它会删掉超限镜像**：

```make
[ $$limitsize -ge $$imagesize ] || { \
    $(call ERROR_MESSAGE, WARNING: Image file $@ is too big: ...); \
    rm -f $@; }
```

### 为什么不能调大 `KERNEL_SIZE`

`target/linux/qualcommbe/image/ipq53xx.mk:59` 的注释写得很清楚：

```
# The kernel FIT is dd'd into 0:HLOS (mmcblk0p12, 7 MiB) ...
# A default build is ~5.75 MiB, so refuse to build anything
# the partition cannot hold. A truncated kernel never boots.
```

HLOS 分区物理上就是 7 MiB，调大 = 内核被截断 = 变砖。只能把内核压小。

### 定位过程（含一个排除项）

先排除误判：`arch/arm64/boot/Image` 有 **565MB**，但那是 **initramfs 变体**
（`.init.data` 542MB，整份 rootfs 被嵌入），是 OpenWrt 双配置机制的正常产物。
真正进 factory 镜像的是 `$(KDIR)/Image` = **23.39MB**。

各段实际占用：

```
.text        11.01 MB
.BTF          4.15 MB   ← 元凶
.rodata       3.43 MB
.rela.dyn     2.08 MB
.data         1.48 MB
```

`.BTF`（BPF Type Format）在 arm64 上是**可加载段**，会被算进 Image。
实测其压缩率：

```
.BTF 原始 4,149,890 → gzip 后 1,341,601（占超限量的 143%）
```

### 修复

`.config`：

```
# CONFIG_KERNEL_DEBUG_INFO_BTF is not set
# CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES is not set
```

BTF 的用途是 eBPF 的 CO-RE（Compile Once – Run Everywhere），需要 `bpftool`/`bpftrace`/
`bcc`/`xdp-tools` 等工具读取。本固件**没有安装任何这类工具**，`libbpf` 也只在运行
CO-RE 程序时才需要 `.BTF`，因此关闭它不影响任何现有功能。

> 尝试过但无效的方案：`# CONFIG_KALLSYMS_UNCOMPRESSED is not set`
> 被 `include/kernel-defaults.mk:113` 硬编码覆盖：
> ```make
> $(if $(CONFIG_KERNEL_KALLSYMS),echo "CONFIG_KALLSYMS_UNCOMPRESSED=y" >> $(LINUX_DIR)/.config.target,true)
> ```
> 已从 `env/kernel-config` 中移除该行以免误导。

### 证据

```
内核 Image：  23,394,312 → 19,200,008 字节（-4.19 MB，正好是 .BTF 的大小）
FIT：          8,276,672 →  7,006,160 字节
分区限制：                  7,340,032 字节（7168k）
余量：                        333,872 字节  ✅
factory.bin 头部 sha256 == FIT 文件 sha256（f5ff9ce6d65d8f54...）✅ 位置正确
```

---

---

## 7. `tzapp` 保留内存地址与硬件不符（安全世界内存被内核占用）

**文件**：`target/linux/qualcommbe/dts/ipq5332-common.dtsi`
**补丁**：`patches/0006-dts-tzapp-and-wcss-reserved-memory.patch`

### 症状

`ath12k_wifi7_ahb` 探测失败，`qcom-wcss-secure-pil` 报
`error -5 initializing firmware ath12k/IPQ5332/hw1.0/q6_fw0.mdt`，
`RootPD boot failed`，整机无任何射频（`iw dev` 为空、`/sys/class/ieee80211/` 为空）。

### 根因

这套 LEDE target 自带的一次性提交（`471321693`）把 TZ（安全世界）的保留区写在
`0x4d400000`，而设备实际的 TZ 运行内存在 `0x49b00000`：

| 来源 | tzapp 地址 |
|---|---|
| 厂商原厂固件（`mmcblk0p22` FIT，`JDBox RE-CS-06 4.5.2.r4525`） | `0x49b00000` +6MB |
| VIKINGYFY/immortalwrt 的 `ipq5332-common.dtsi` | `0x49b00000` +6MB |
| 本 target 原值 | `0x4d400000` +6MB ❌ |

结果 Linux 把 `0x49b00000~0x4a4fffff` 当普通内存使用，覆盖 TZ 的运行时数据，
导致所有 SCM 调用（含 PAS init）行为异常。

### 修复

```dts
tzapp: tzapp@49b00000 {
	reg = <0x0 0x49b00000 0x0 0x00600000>;
	no-map;
};
```

### 证据

设备实测 `/proc/iomem`：

```
49b00000-4a4fffff : reserved
```

---

## 8. WCSS / WiFi 节点保留内存布局与硬件不符

**文件**：`target/linux/qualcommbe/dts/ipq5332-common-wifi.dtsi`、
`target/linux/qualcommbe/dts/ipq5322-re-cs-06.dts`

### 根因

原 DTS 自行发明了一套保留区，与厂商 DTB、VIKINGYFY target 均不一致：

| 项 | 原值 | 改为 | 依据 |
|---|---|---|---|
| `q6_region` | 43MB（后被缩到 35MB） | **48MB**（`0x4a900000` + `0x3000000`） | 上游补丁 *"reserve 48 MiB to bring up q6"*、VIKING 一致 |
| `sbl@4a500000` | 未保留 | 保留 1MB | 厂商 DTB、VIKING 均有 |
| wifi0（AHB 2.4G）memory-region | 5 个（q6/host-ddr/m3-dump/q6-caldb/mlo） | **2 个**（q6-region、host-ddr-mem） | 他的 `ipq5332-common-wifi.dtsi` |
| wifi0 `qcom,ath12k-fw-memory-mode` | 无（=模式 0） | **`<1>`** | 同上 |
| wifi0 `qcom,ath12k-low-memory` | 有 | 删除 | 同上 |
| wifi1（QCN9274 PCI）memory-region | 固定 50MB host-ddr + mlo | **不绑定**（驱动自行分配） | 同上 |
| 新增属性 | — | `qcom,rx-skb-slab`（两颗都加） | 同上 |

配套：`CONFIG_CMA_SIZE_MBYTES` 64 → **128**（`patches/0007-target-config-cma-128.patch`），
因为新方案里 CALDB / M3 dump / MLO 共享池改为 **CMA 动态分配**。

### 证据

新镜像的 DTB（从 `sysupgrade.bin` 解 FIT 后反编译）：

```
tzapp@49b00000   reg = <0x00 0x49b00000 0x00 0x600000>
wcss@4a900000    reg = <0x00 0x4a900000 0x00 0x3000000>
sbl@4a500000     reg = <0x00 0x4a500000 0x00 0x100000>
wifi@c000000     memory-region = <0x26 0x26>
                 memory-region-names = "q6-region\0host-ddr-mem"
                 qcom,ath12k-fw-memory-mode = <0x01>
                 qcom,rx-skb-slab
wifi@0 (PCI)     qcom,ath12k-fw-memory-mode = <0x01>
                 qcom,rx-skb-slab        （无 memory-region）
```

DTB 大小 30,615 字节，VIKING 的为 30,631 字节。

---

## 9. TZ 拒绝 `PAS_INIT_IMAGE`（v1 命令），Q6 无法启动

**文件**：`target/linux/qualcommbe/patches-6.18/0900-firmware-qcom-scm-try-pas-init-v2.patch`
**补丁**：`patches/0008-kernel-scm-pas-init-v2.patch`

### 症状

```
qcom-wcss-secure-pil d100000.remoteproc: error -5 initializing firmware .../q6_fw0.mdt
remoteproc remoteproc0: Failed to load program segments: -5
ath12k_wifi7_ahb c000000.wifi: RootPD boot failed
```

### 根因（ftrace 硬证据）

打开 `qcom_scm` 的 tracepoint 后抓到：

```
scm_smc_request: smc_id:0x42000201 svc_id:0x02 cmd_id:0x01 args_cnt:2 args:{0xd,0x7b108000}
scm_smc_done:    smc_id:0x42000201, ret:0 res_to_callee:0xffffffffffffffff
```

- 我们发的是 **PAS init v1**：`svc 0x02 / cmd 0x01`，2 个参数（pas_id `0xd` + 元数据物理地址）
- TZ 返回原始值 **-1**，`qcom_scm_remap_error(-1)` 映射成 `-EIO(-5)`

已排除的原因：

| 怀疑点 | 排除方式 |
|---|---|
| 固件文件损坏/不对 | 换厂商 `q6_fw0.mdt`、换 VIKING 的（md5 `250e1642`）→ 均仍是 -5 |
| 驱动/内核代码不同 | 与 VIKING 内核对比：wcss/pil/scm 相关字符串 208/208 完全一致 |
| DTS 差异 | rproc 节点逐字段对比，仅 phandle 编号不同 |

反汇编厂商内核（5.4.213，`mmcblk0p22`）发现它走的是 **v2 命令**：

```
0x559714:  mov r2, #0x1a     ← PAS_INIT_IMAGE_V2 命令号
0x559714:  mov r3, #0x83     ← 3 个参数（VAL, RW, VAL）
0x559770:  mov r2, #0x1      ← 失败才回退 v1
0x559770:  mov r3, #0xc      ← 2 个参数
```

且厂商内核的 SCM 统计中 `svc 0x02 / cmd 0x01` 出现 4 次 —— 说明**这台机器的 TZ 支持 PAS**，
只是需要用 v2 格式（带元数据长度）。

### 修复

`qcom_scm_pas_init_image()` 改为先发 v2，失败回退 v1（原行为不变），并打点：

```c
desc.cmd = QCOM_SCM_PIL_PAS_INIT_IMAGE_V2;          /* 0x1a */
desc.arginfo = QCOM_SCM_ARGS(3, VAL, RW, VAL);
desc.args[2] = size;
ret = qcom_scm_call(...);
dev_info(dev, "pas init image v2: pas_id=%u len=%zu ret=%d res=%lld\n", ...);
if (ret) {
	desc.cmd = QCOM_SCM_PIL_PAS_INIT_IMAGE;      /* 0x01 */
	desc.arginfo = QCOM_SCM_ARGS(2, VAL, RW);
	ret = qcom_scm_call(...);
	dev_info(dev, "pas init image v1 fallback: ret=%d res=%lld\n", ...);
}
```

### 验证状态

- ✅ 补丁编入内核：`strings vmlinux | grep "pas init image v2"` 命中
- ⏳ **设备端效果未验证**（需刷机后看 dmesg 里 `res=` 的值）

---

## 10. ath12k 补丁集重组：CMA 动态分配 + AHB 故障恢复 + WSI 组准入

**目录**：`package/kernel/mac80211/patches-qualcommbe/ath12k/`
**补丁**：`patches/0009-ath12k-patchset-tracked-changes.patch`、`patches/0010-ath12k-patchset-final.tar.gz`

### 背景

VIKINGYFY 的同一块板子 WiFi 可用，其做法（提交 `b4f7857f9`、`f111cdf6d`、
`1beba155f`、`a32636c54`，以及 ath12k 补丁 `315-*`、`330`、`910`、`105`、`101`、`352`）
是把固件内存改为**按需 CMA 分配**，并让**硬件组能容忍失效成员**。

最关键的一条（`910` 补丁原文）：

> A WSI graph can describe a QCN9274 which never enumerated on PCI.
> **The remaining devices then wait for the missing member before starting firmware.**

这正好解释我们的现象：AHB（`wifi0`）在 TZ 处失败后，同组的 PCI 那颗一直停在
`QCN9274 MHI selection` 之后再无输出 —— 它在等一个永远不会就绪的成员。

### 改动

| 操作 | 补丁 | 作用 |
|---|---|---|
| 删除 | `315-01-share-fixed-mlo-memory` | 旧的固定 MLO 池方案 |
| 删除 | `315-02-rootpd-crash-recovery` | 被 315-03 取代 |
| 删除 | `317-use-reserved-pci-host-ddr` | 固定 PCI host-DDR，已废弃 |
| 删除 | `338-low-memory-host-resources` | 被 315-02 取代 |
| 删除 | `342-host-ddr-view-within-wcss-memory` | 被 315-02 取代 |
| 删除 | `335-arm-UserPD-completions-before-auth` | 被新版 330 合并 |
| 替换 | `313`、`330` | 换成配套新内存方案 / 含 fatal IRQ + 独立重载 |
| 新增 | `315-01-firmware-memory-contracts` | 命名保留区查找 + 共享 MLO 所有权 + QMI 内存类型契约 |
| 新增 | `315-02-firmware-memory-allocation` | 逐段 DMA 所有权、有界 AHB host-DDR 视图、CALDB/M3 用 CMA |
| 新增 | `315-03-rootpd-crash-recovery` | RootPD 崩溃上报 + WSI 组恢复 |
| 新增 | `915-firmware-mlo-group-admission` | 只让兼容固件进 MLO 组 |
| 新增 | `916-assign-device-id-from-WSI-index` | radio 编号按 WSI 定死，`radio0/radio1` 不再每次开机换 |
| 新增 | `917-check-wsi-pci-endpoints` | **WSI 组缺成员时不等**，走单设备路径 |
| 新增 | `918-quiesce-mhi-before-controller-teardown` | 拆设备/reload 时先 quiesce MHI，防 QRTR UAF |

`918` 修的是运行期崩溃（不是启动失败）：固件恢复期间 MHI 已 power up 但数据面还没置
`INIT_DONE`，此时拆设备会跳过 PCI power-down，QRTR 通道内存被释放后仍被广播
（例如拆 AHB 伴生设备时）引用 → `mhi_queue_skb()` use-after-free。
我们排障时正是靠手动 `unbind/bind` 重载，正好踩在这个窗口里。

### 证据

在干净的 `backports-7.2` 源码上逐条 `patch -p1` 应用：**0 失败**。
编译后检查源码痕迹：

```
315-01 → qmi.c 命名保留区查找
315-02 → qmi.c dma_alloc_coherent ×3
315-03 → ahb.c "rootpd" ×24
330    → ahb.c userpd_crashed ×6
917    → core.c wsi/enumerat ×4
918    → mhi.c ath12k_mhi_stop(ab_pci, false)
```

---

## 11. 仍未解决 / 待验证

| 项目 | 状态 |
|---|---|
| TZ 是否接受 PAS v2（AHB 能否真正启动） | ⏳ 待刷机验证，看 dmesg `pas init image v2: ... res=` |
| PCI（QCN9274）是否能在 AHB 失败时独立起来 | ⏳ 待验证（917 + 315-* 的作用） |
| VIKING 的 AHB 是否真能工作 | 🔎 证据倾向于"能"：其 `350` 补丁正文明确提到 **BE6500 IPQ5332 的 2.4GHz TCP 有多秒完成停顿**，说明他的 2.4G 在跑流量 |
| 若 AHB 仍失败，下一步 | 换他的固件文件（`/tmp/vkfw.tar`，`q6_fw0.mdt` md5 `250e1642`）再试；仍失败则改用与他的镜像做运行时对比（dmesg + ftrace 抓他成功时的 SCM 参数） |

### 刷机后需要采集的三条命令

```sh
dmesg | grep -iE "pas init image|RootPD|UserPD fatal|probe with driver"
iw phy | grep -E "^Wiphy|Band"
cat /sys/class/ieee80211/phy*/device/uevent | grep DRIVER   # ahb=内部2.4G，pci=QCN9274
```

## 附录 A：host 端 `cond.m4` 被 gnulib 覆盖（阻断构建）

**脚本**：`scripts/fix-host-aclocal.sh`（幂等，可重复执行）

### 症状

```
configure.ac:30: error: possibly undefined macro: AM_CONDITIONAL
autoreconf: error: .../staging_dir/host/bin/autoconf failed with exit status: 1
configure: error: cannot find required auxiliary files: ar-lib
    ERROR: package/feeds/packages/dcwapd failed to build.
```

### 根因

- OpenWrt 通过 `ACLOCAL_INCLUDE` 传 `-I $(STAGING_DIR_HOST)/share/aclocal`（`include/package.mk:203`）
- `aclocal` 对**同名 `*.m4` 只采用第一个命中的文件**
- host 编译 `gettext-full`（含 gnulib）时，gnulib 把它的 `cond.m4`（只定义 `gl_COND`）
  装进了 `share/aclocal/`
- 该目录排在 automake 自带的 `share/aclocal-1.18/` 之前，于是 automake 的
  `cond.m4`（定义 `AM_CONDITIONAL`）被遮蔽 → 宏消失 → autoconf 失败 → `ar-lib` 也未生成

实测冲突文件**只有 `cond.m4` 一个**。

### 处理

```bash
mv staging_dir/host/share/aclocal/cond.m4 \
   staging_dir/host/share/aclocal/cond.m4.gnulib.bak
```

去掉 `.m4` 后缀后 aclocal 不再扫描它，automake 自己的版本正常生效。
`make dirclean` 或重新构建 gettext host 后可能复发，重跑 `scripts/fix-host-aclocal.sh` 即可。

### 证据

```
dcwapd:  aclocal.m4 中 AM_CONDITIONAL 定义数  0 → 1
         config.status 生成 ✅   .configured ✅   .built ✅
```

---

## 附录 B：取舍 —— 放弃 shadowsocks-rust 以避开 Rust/LLVM

依赖链：

```
luci-app-ssr-plus
  └─ select ...INCLUDE_Shadowsocks_Rust_Client
      └─ shadowsocks-rust-sslocal
          └─ PKG_BUILD_DEPENDS := rust/host   （rust 1.99.1，源码编译 LLVM，4 核约 1-2 小时）
```

处理（`.config`）：

```
# CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_Shadowsocks_Rust_Client is not set
# CONFIG_PACKAGE_shadowsocks-rust-sslocal is not set
```

包数 477 → 476，其余代理内核（xray / ssr-libev / v2ray / sing-box / trojan）全部保留，
`luci-app-passwall2`、`luci-app-ssr-plus`、`luci-app-openclash`、`luci-app-homeproxy` 均为 `=y`。

---

## 附录 C：默认中文 / 主题 / 主机名

**文件**：`overlay/files/etc/uci-defaults/99-default-zh-cn`

采用两层实现：

1. 编译期：`.config` 里 `CONFIG_LUCI_LANG_zh_Hans=y`（语言包进固件）
2. 首次启动：uci-defaults 脚本写入运行时配置

```sh
uci set luci.main.lang='zh_cn'
uci set luci.themes.Vantage='/luci-static/vantage'
uci set luci.main.mediaurlbase='/luci-static/vantage'
uci set system.@system[0].hostname='JDCloud-BE6500'
uci set system.@system[0].timezone='CST-8'
uci set system.ntp.server='ntp.aliyun.com' 'cn.pool.ntp.org' 'time.cloudflare.com'
uci commit
```

主题脚本编号 `99-` 大于 vantage 主题自带的 `30_luci-theme-vantage`，
保证在其注册主题之后才设置 `mediaurlbase`，不会被覆盖。

---

## 附录 D：Docker 内核支持

**文件**：`overlay/env/kernel-config`（43 行，由 `include/target.mk:165` 的
`LINUX_KCONFIG_LIST` 合并进内核配置）

覆盖 cgroup / namespace / netfilter / overlayfs 等 Docker 运行必需项。
镜像内核最终确认值：

```
CONFIG_CGROUPS=y        CONFIG_NAMESPACES=y    CONFIG_NET_NS=y
CONFIG_BRIDGE=y         CONFIG_VETH=m          CONFIG_OVERLAY_FS=y
```

选方案 B（自建内核配置）而非砍掉 Docker 的原因：设备 eMMC 系统分区 2GB，
放得下 Docker 镜像，没必要为体积牺牲功能。

---

## 附：修改文件总表

| 文件 | 类型 | 说明 |
|---|---|---|
| `package/firmware/ipq-wifi/Makefile` | 补丁 0001 | +8 行 `Build/Prepare`，引入本地 BDF |
| `package/kernel/mac80211/files/lib/wifi/mac80211.sh` | 补丁 0002 | 默认国家码 US → CN |
| `package/network/services/hostapd/files/hostapd.sh` | 补丁 0003 | 802.11k 默认开 |
| `package/libs/gettext-full/*` | 补丁 0004 | 版本回退到上游 0.24.2 |
| `package/kernel/mac80211/patches-qualcommbe/build/503-*.patch` | 补丁 0005 | 新增，`struct sockaddr_unsized;` 前向声明 |
| `.config` | 配置 | BTF 关闭、SS-Rust 关闭、中文语言包、vantage 主题、目标设备 |
| `env/kernel-config` | overlay | Docker 内核选项（+ 体积控制注释） |
| `files/etc/uci-defaults/99-default-zh-cn` | overlay | 中文 UI / 主题 / 主机名 / 时区 / NTP |
| `package/custom/*` | 第三方包 | vantage 主题、partexp、gecoosac、natmapt、mini-diskmanager、fullconenat、wolplus |
| `staging_dir/host/share/aclocal/cond.m4` | 环境 | 隔离 gnulib 版本（脚本化） |
| `target/linux/qualcommbe/dts/ipq5332-common.dtsi` | 补丁 0006 | `tzapp` → `0x49b00000` |
| `target/linux/qualcommbe/dts/ipq5332-common-wifi.dtsi` | 补丁 0006 | wifi0/wifi1 保留区与内存模式对齐 |
| `target/linux/qualcommbe/dts/ipq5322-re-cs-06.dts` | 补丁 0006 | `sbl@4a500000` + `q6_region` 48MB |
| `target/linux/qualcommbe/config-6.18` | 补丁 0007 | `CONFIG_CMA_SIZE_MBYTES` 64 → 128 |
| `target/linux/qualcommbe/patches-6.18/0900-*.patch` | 补丁 0008 | PAS init 先发 v2（cmd 0x1a），失败回退 v1 |
| `package/kernel/mac80211/patches-qualcommbe/ath12k/*` | 补丁 0009/0010 | 固件内存改 CMA 动态分配 + AHB 故障恢复 + WSI 组准入 + MHI quiesce |

---

# 第三轮：无线真正出信号（build14 → build17）

> 本节只记录结论。完整排查过程（日志原文、ftrace、厂商内核反汇编、逐轮对照实验、
> 被否决的方案）见 **[WIFI-FIX.md](WIFI-FIX.md)**。

前两轮解决了"Q6 能启动"，但设备仍然没有 SSID。本轮定位到三个独立故障并逐个修掉。

## 12. 故障一：两颗芯片固件版本不一致 → MLO 断言 → 重启循环

### 现象

```
[73.0] ath12k_wifi7_ahb: fw_version ... WLAN.WBE.1.7-01733-QCAHKSWPL_SILICONZ-1   ← 2.4G
[73.5] ath12k_wifi7_pci: fw_version ... WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1   ← 5G/6G
[74.7] ath12k_wifi7_ahb: WSI group 0: MLO enabled for 2 devices
[76.1] qcom-wcss-secure-pil: fatal error received: err_smem_ver.2.1
       platform_mlo.c:2038 Assertion !partner_chip_crash_ind failed
[76.2] remoteproc remoteproc0: crash detected in q6wcss: type fatal error
```

随后 phy0 虽然注册，但所有 WMI 命令失败：

```
failed to send WMI_SET_INIT_COUNTRY CMD :-108
fail to start mac operations in pdev idx 0 ret -108
```

并且**每隔 2-3 分钟整机重启一次**（`/proc/sys/kernel/panic=3`，panic 后 3 秒自动重启）—— 重启又让
`git.openwrt.org` 的下载全部失败，编译连续失败两次。

### 根因

本板两颗芯片被 DTS 绑成一个 WSI/MLO 组（`qcom,wsi-controller` + ports 端点），
MLO 协作要求双方**跑同一份固件构建**。而 DD-WRT 固件包（`ath-firmware-ddwrt`，commit
`bd7c0abd`）里 IPQ5332 是 `WBE.1.7-01733`、QCN9274 是 `WBE.1.6-01270` —— 版本不匹配，
QCN9274 在握手时上报 crash indication，IPQ5332 固件断言 `!partner_chip_crash_ind` 失败。

对照 VIKINGYFY 的可用镜像：两颗芯片的 `fw_version.txt` 都是 `WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1`。

### 修改

新增本地固件覆盖目录，并让 `Build/Prepare` 在解包后将其覆盖到构建目录：

```
package/firmware/ath-firmware-ddwrt/files/ath12k/IPQ5332/hw1.0/   （42 个文件，8.1 MB，不含 board-2.bin）
package/firmware/ath-firmware-ddwrt/Makefile                      （Build/Prepare 增加一次 $(CP)）
```

- `q6_fw0.mdt` md5 = `250e1642000d54df6c13dabc08560949`（与 VIKING 的逐字节一致）
- `board-2.bin` 不覆盖 —— 由 `ipq-wifi` 提供本板 BDF

### 结果

```
ath12k_wifi7_ahb: fw_version ... WLAN.WBE.1.6-01270
ath12k_wifi7_pci: fw_version ... WLAN.WBE.1.6-01270
崩溃次数：0（此前每轮启动必崩一次）
重启循环：消失
```

---

## 13. 故障二：校准数据在开机时不存在（hotplug 时序不可靠）

### 现象

```
ath12k_wifi7_ahb: qmi failed to load CAL data file: cal-ahb-c000000.wifi.bin
ath12k_wifi7_ahb: qmi failed to load calibrated data :-110
```

### 根因

两个 cal 文件本应由 `/etc/hotplug.d/firmware/12-ath12k-caldata` 从 `0:ART`（`/dev/mmcblk0p17`）
按偏移 dd 出来：

| 目标文件 | 源 | 偏移 | 长度 |
|---|---|---|---|
| `ath12k/IPQ5332/hw1.0/cal-ahb-c000000.wifi.bin` | `0:ART` | `0x1000` | `0xf800`（63,488 B） |
| `ath12k/QCN9274/hw2.0/cal-pci-0001:01:00.0.bin` | `0:ART` | `0x58800` | `0x2d000`（184,320 B） |

脚本手动执行立即成功，说明脚本本身没问题 —— 问题在**依赖 uevent 触发的时机**，固件请求 cal
数据时文件还没生成，超时后射频初始化失败。

### 修改

新增开机预提取脚本（优先级 09，早于 `S10boot` 的 kmodloader）：

```
target/linux/qualcommbe/ipq53xx/base-files/etc/init.d/ath12k-caldata
```

它复用 hotplug 脚本里已有的**按板型偏移逻辑**，只补"文件不存在则提前生成"这一步：

```sh
for fw in ath12k/IPQ5332/hw1.0/cal-ahb-c000000.wifi.bin \
          ath12k/QCN9274/hw2.0/cal-pci-0001:01:00.0.bin
do
    [ -s "/lib/firmware/$fw" ] && continue
    FIRMWARE="$fw" sh /etc/hotplug.d/firmware/12-ath12k-caldata
done
```

镜像里自动生成 `/etc/rc.d/S09ath12k-caldata` 与 `K99ath12k-caldata`。

---

## 14. 故障三（最后一个）：2.4 GHz 因 HT 能力位缺失无法启动

### 现象

5G 正常，2.4G 的 hostapd 直接 disabled：

```
Driver does not support configured HT capability [MAX-AMSDU-7935]
wlan0-0: interface state COUNTRY_UPDATE->DISABLED
wlan0-0: AP-DISABLED
```

`iwinfo` 里 2.4G 显示 `HT Mode: NOHT`、`Tx-Power: 0 dBm`。

### 根因（上游 bug，单 wiphy 多 band 场景）

本板两颗芯片在驱动里合成**一个 wiphy**（`phy0` 同时承载 Band 1=2.4G、Band 2=5G），
而两段 band 的 HT 能力不同：

```
Band 1 (2.4G) Capabilities: 0x11e7   ← 无 0x800（MAX-AMSDU 7935）
Band 2 (5G)   Capabilities: 0x19e7   ← 有 0x800
```

OpenWrt 的 `mac80211.sh` 把 `iw phy` 输出的**所有 band** 的 `Capabilities:` 按位或，
得到 `0x19e7` 后统一下发给每个 radio —— 于是 2.4G 也被要求了 `MAX-AMSDU-7935`，
hostapd 用 2.4G 自己的能力校验时失败，BSS 被禁用。

驱动侧源头在 `ath12k_mac_setup_ht_cap()`：该函数按 band 生成 HT 能力位图，却把
`IEEE80211_HT_CAP_MAX_AMSDU` 挂在固件 **VHT** 能力字上：

```c
if (ar_vht_cap & WMI_VHT_CAP_MAX_MPDU_LEN_MASK)      /* 2.4G 无 VHT → 恒为 0 */
        ht_cap.cap |= IEEE80211_HT_CAP_MAX_AMSDU;
```

### 修改（补丁 0011）

无条件置位——7935 字节 A-MSDU 在所有频段（含 2.4G HE）都由硬件支持：

```
package/kernel/mac80211/patches-qualcommbe/ath12k/331-ath12k-advertise-max-amsdu-on-all-bands.patch
```

### 曾尝试但否决的方案

| 方案 | 结果 |
|---|---|
| 改 `wifi-scripts` 按 band 取 caps | ❌ 实测导致 netifd 完全不注册 phy，WiFi 彻底起不来，已撤回 |
| 让 2.4G 不声明该能力 | ⚠️ 能起来，但属于功能回退 |

VIKINGYFY 仓库**没有**此类改动（`git grep MAX_AMSDU` 无命中；其 wifi-scripts 与上游一字不差），
说明这是上游在"单 wiphy 多 radio"场景下的缺陷，不能靠照抄解决。

---

## 15. 附带改动：wpad 换成完整版

精简版 `wpad-basic-mbedtls` 不含 EAP，导致 LuCI 的 **802.11k / 802.11v 复选框整块不渲染**
（`wireless.js` 里它们被包在 `if (L.hasSystemFeature('hostapd','eap'))` 内）。

```
target/linux/qualcommbe/Makefile:   wpad-basic-mbedtls → wpad-mbedtls
.config:                            CONFIG_PACKAGE_wpad-mbedtls=y
```

注：802.11k 在功能上一直是开的（`hostapd.sh:873` 默认 1 → 生成 `rrm_neighbor_report=1`、
`rrm_beacon_report=1`），只是界面不显示；换包后界面才会出现复选框。

---

## 16. 遗留与后续

| 项 | 状态 |
|---|---|
| 2.4G 出 HE20 并实测打流 | 待 build17 刷机后验证 |
| 三频（5.2+5.8 或 6G） | 硬件 QCN9274 为双频，但 DTS `qcom,num-radios=<1>` 只暴露 2 个 band；国内 6GHz 未开放，暂不展开 |
| `products-sha256sums.txt` | 需按每次出包更新 |

---

# 第四轮：开机 60 秒黑洞（build19 → build21）

## 17. 故障四：Q6 上电被固件加载器阻塞 60 秒

### 17.1 现象

无线可用要 ~140 s。时间线里 `ath12k_wifi7_ahb` 打完 `Hardware name: ipq5332 hw1.0`
（8.7 s）之后，**整整 60.8 秒没有任何日志**，然后才 `powering up q6wcss`（69.6 s）。
之前多次误判为 CAC 慢（CAC 恰好也是 ~60 s）。

### 17.2 根因

1. ath12k 对 AHB（SoC 内的 IPQ5332）先试 **fw api 2**（单文件 `firmware-2.bin`），
   拿不到再回退 **api 1**（`q6_fw0.mdt` + `q6_fw1.mdt`）。
2. 板子的固件包里 `ath12k/IPQ5332/hw1.0/` **没有 `firmware-2.bin`**（原厂就没带，
   42 个文件里只有 q6_fw0.* / q6_fw1.* 分离镜像）。
3. `request_firmware()` 缺文件时进入 userspace 回退路径，等
   `FW_LOAD_TIMEOUT_MS = 60000` 毫秒才返回 `-110`（`-ETIMEDOUT`）。

### 17.3 修复

补丁 `919-ath12k-request-optional-fw-api2-without-fallback.patch`：把这个**可选**探测
改用 `request_firmware_direct()`，缺文件立即 `-ENOENT` 回退 api 1，不再等 userspace。
影响面仅此一次请求，全局固件热插拔回退保持开启。

（曾用「`ignore_sysfs_fallback=1`」的全局方案，效果相同但会关掉全系统的固件热插拔回退，
维护性差，已弃用。）

### 17.4 实测

| 状态 | `Hardware name` → `powering up q6wcss` | 全局回退 |
|---|---|---|
| 原始 | 8.747 s → 69.601 s（60.8 s，`-110`） | 开 |
| sysctl 方案（build20，弃用） | 8.934 s → 8.966 s（32 ms） | 关 |
| **补丁 919（build21）** | **8.824 s → 8.832 s（8 ms）** | **开** |

### 17.5 附带改动

`.config` 打开 `CONFIG_PACKAGE_ATH_DEBUG=y`（经
`package/kernel/mac80211/ath-qualcommbe.mk:45` 映射到 `CPTCFG_ATH12K_DEBUG`）。
模块 927,456 B → 1,046,000 B，默认 `debug_mask=0` 不产生任何日志；需要时可运行时
`echo 0x... > /sys/module/ath12k/parameters/debug_mask`，不必重编。

⚠️ OpenWrt 的模块参数文件是 **`/etc/modules.conf`**（`ubox/kmodloader.c: load_options()`），
不是 `/etc/modprobe.d/*.conf` —— 放错位置参数会静默失效。

### 17.6 出包

| 版本 | sysupgrade sha256 | 说明 |
|---|---|---|
| build19 | — | 去掉 `luci-app-wol`，验证 802.11k/v |
| build20 | `3c4bd8bf668ff2bea02df6ab378cecbc3b30090057afa6dffe6c917ecb9b6c58` | sysctl 全局方案（**弃用**，勿刷） |
| **build21** | `87de9ef25897c131e3db43eb08c8b174f0dcc38d07c1cd0be45738793cf8b696` | **最终版**：补丁 919 + 调试模块 + 无 wol |
| build21 factory | `9d2d1021c9624ded798bd2bd833c03f6a84852044a7b668e8b670662baa2b7eb` | |
