# JDCloud BE6500 (RE-CS-06) 自定义 LEDE 固件 — 构建说明

本目录记录了为 **JDCloud BE6500 / RE-CS-06（IPQ5322，Wi-Fi 7，qualcommbe/ipq53xx）**
编译自定义固件时的全部源码改动、构建步骤与验证方法。

---

## 1. 固件信息

| 项目 | 值 |
|---|---|
| 源码 | coolsnowwolf/lede（fork），HEAD `e5dc1a534` |
| 版本 | OpenWrt 24.10.5，`r8302-e5dc1a534` |
| 目标平台 | `qualcommbe` / `ipq53xx` |
| 设备 | `jdcloud_re-cs-06`（JDCloud BE6500） |
| SoC | Qualcomm IPQ5322（aarch64 cortex-a53，musl） |
| 内核 | Linux **6.18.62** |
| WiFi 驱动 | `ath12k`（backports **7.2**） |
| 包管理器 | opkg / ipk（`CONFIG_USE_APK` 未启用） |
| 包数量 | **456** |
| 存储 | eMMC，系统分区 2GB |
| 默认 UI | 简体中文（`zh_cn`） |
| 默认主题 | `vantage` |
| 主机名 | `JDCloud-BE6500` |
| 国家码 | `CN` |
| 802.11k / 802.11r | 默认开 / 默认关 |

### 产物

```
bin/targets/qualcommbe/ipq53xx/
├── openwrt-qualcommbe-ipq53xx-jdcloud_re-cs-06-squashfs-factory.bin     149.3 MB  首次刷机
├── openwrt-qualcommbe-ipq53xx-jdcloud_re-cs-06-squashfs-sysupgrade.bin  149.0 MB  系统升级
├── openwrt-qualcommbe-ipq53xx-jdcloud_re-cs-06-initramfs-uImage.itb     180.3 MB  内存运行/救砖
├── openwrt-qualcommbe-ipq53xx-jdcloud_re-cs-06.manifest                           包清单
└── sha256sums
```

sha256：

```
a2be0e37e2d4db37b983f200ac7fbe7315b7e4a321d4e76ac3d18dff5cb700c3  *...squashfs-factory.bin
719e0675ba48d74197e02c63481e099b6602870d6784626c74947e1371738a69  *...squashfs-sysupgrade.bin
28352fc18d9bc8f85ed15b6c41080622bc05830d4584dd4171d840bd734f8bd4  *...initramfs-uImage.itb
```

---

### WiFi 修复（第二轮，2026-11-17）

首轮刷机后虽然 BDF 已打进固件，但射频仍然完全不可用（`iw dev` 空）。
第二轮定位并修复了 5 项，详见 `CHANGES.md` 第 7–11 节：

| # | 改动 | 补丁 |
|---|---|---|
| 7 | `tzapp` 保留地址 `0x4d400000` → **`0x49b00000`**（原值会踩安全世界内存） | `0006` |
| 8 | WCSS/WiFi 保留内存对齐硬件：`q6_region` 48MB、`sbl` 保留、wifi0 只留 2 个 region + `fw-memory-mode=1`、wifi1 不绑定 region | `0006` |
| 9 | TZ 拒绝 PAS init v1（ftrace 抓到 `res=-1`）→ 新增**先发 v2（cmd `0x1a`，带长度）失败回退** | `0008` |
| 10 | ath12k 补丁集重组：固件内存改 **CMA 动态分配**、AHB 故障可恢复、**WSI 组缺成员不再等待**、MHI quiesce | `0009`/`0010` |
| — | 配套 `CONFIG_CMA_SIZE_MBYTES` 64 → **128** | `0007` |

状态：全部已编入镜像；**设备端效果待刷机验证**（`dmesg | grep "pas init image"`）。

## 2. 目录结构

```
firmware-changes/
├── README.md                        本文件：构建、部署、验证
├── CHANGES.md                       逐项改动说明（症状 → 根因 → 修复 → 证据）
├── patches/
│   ├── 0001-ipq-wifi-install-local-bdf.patch        WiFi 无信号根因（BDF 打包）
│   ├── 0002-mac80211-default-country-cn.patch       国家码默认 CN
│   ├── 0003-hostapd-default-80211k-on.patch         802.11k 默认开启
│   ├── 0004-gettext-full-bump-to-0.24.2.patch       修复 gnulib 补丁冲突
│   └── 0005-backports-sockaddr-unsized.patch        backports 7.2 在 6.18.62 上的编译修复
├── overlay/                         直接放入源码树的文件（均被 .gitignore 忽略，需单独复制）
│   ├── env/kernel-config            内核配置片段（Docker 支持 + 体积控制）
│   └── files/etc/uci-defaults/99-default-zh-cn   中文 UI / vantage / 主机名 / 时区
├── config/
│   └── config-key-options.txt       关键 .config 选项摘录（461 行）
└── local-packages/
    └── package-custom.tar.gz        第三方包源码（12 MB）
```

---

## 3. 应用改动（从干净仓库复现）

```bash
git clone http://10.0.0.166:1005/qianzf/lede.git
cd lede
git checkout e5dc1a534

# 1) 打补丁
for p in /path/to/firmware-changes/patches/0*.patch; do
    git apply "$p"          # 0004 是 gettext 版本回退，可能需 git apply -3
done

# 2) 放入 overlay 文件（注意：/env 与 /files 在 .gitignore 中，不会被 git apply 处理）
cp -a /path/to/firmware-changes/overlay/env       .
cp -a /path/to/firmware-changes/overlay/files     .

# 3) 解包第三方包
tar -xzf /path/to/firmware-changes/local-packages/package-custom.tar.gz -C .

# 4) feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 5) 用 config/config-key-options.txt 作为参考配置 .config
make menuconfig        # 目标选 qualcommbe / ipq53xx / JDCloud BE6500
                       # 并确保关闭 CONFIG_KERNEL_DEBUG_INFO_BTF（见 CHANGES 第 6 项）

# 6) 构建
FORCE_UNSAFE_CONFIGURE=1 make -j4 V=w 2>&1 | tee build.log
```

> **`V=w` 的含义**：OpenWrt 默认静默模式会把 **stderr 也重定向到 /dev/null**，
> 导致失败时只看到 `ERROR: package/xxx failed to build` 而没有真正原因。
> `V=w` 只丢弃 stdout（编译进度），保留 stderr（错误/警告），日志保持几十行且错误可见。
> 详见 `include/verbose.mk:52` 的 `SILENT:=>/dev/null $(if $(findstring w,$(OPENWRT_VERBOSE)),,2>&1)`。

---

## 4. 刷机

本机为 **eMMC 机型**，`factory.bin` 需要由 U-Boot / 原厂恢复流程写入，不能通过 LuCI 网页升级。

| 场景 | 使用文件 |
|---|---|
| 原厂固件 → OpenWrt | `*-squashfs-factory.bin`（149 MB） |
| OpenWrt → OpenWrt | `*-squashfs-sysupgrade.bin`（149 MB），可 LuCI 上传 |
| 变砖恢复 | `*-initramfs-uImage.itb`（180 MB），内存运行不写 eMMC |

`factory.bin` 布局（重要，与 boot 相关）：

```
偏移 0x000000   内核 FIT（jdcloud_re-cs-06-uImage.itb，7,006,160 字节）
偏移 0x700000   填充至 7168k 边界
偏移 0x700000+  squashfs rootfs
```

---

## 5. 刷机后验证

### 5.1 WiFi 是否正常（本项目最初的故障点）

```sh
# 期望输出 2 个 Wiphy 及其 Band（wifi0 由 IPQ5332 提供 2.4G，wifi1 由 QCN9274 提供 5G/6G）
iw phy | grep -E "^Wiphy|Band [0-9]"

# 期望看到 ath12k 加载 BDF、board id 22 与 2 被匹配
dmesg | grep -iE "ath12k.*(board|firmware|qmi)" | head -20

# 期望 hostapd 正常起来（无 "Could not set channel" / "BDF" 报错）
logread | grep -i hostapd | tail -20

# 直接检查装到设备上的 BDF（应与 DTS 的 qcom,board-id 一致）
grep -a "qmi-board-id=22" /lib/firmware/ath12k/IPQ5332/hw1.0/board-2.bin
grep -a "qmi-board-id=2"  /lib/firmware/ath12k/QCN9274/hw2.0/board-2.bin
```

### 5.2 默认值是否生效

```sh
uci get luci.main.lang                      # zh_cn
uci get system.@system[0].hostname          # JDCloud-BE6500
uci get luci.main.mediaurlbase              # /luci-static/vantage
uci get wireless.@wifi-device[0].country    # CN
```

### 5.3 Docker

```sh
/etc/init.d/dockerd status
docker info | head -20
```

### 5.4 内核体积余量（构建机侧）

```sh
stat -c %s build_dir/target-*/linux-qualcommbe_ipq53xx/jdcloud_re-cs-06-uImage.itb
# 必须 < 7340032（7168k），当前 7006160，余量 333872 字节
```

---

## 6. 已知的、无需处理的现象

| 现象 | 说明 |
|---|---|
| `curl: (22) ... 404` + `Download failed.` | 部分包在 openwrt 官方镜像不存在，自动回退 git clone，属正常 |
| `WARNING: modpost: missing MODULE_DESCRIPTION()` | 内核 6.18 新增的严格检查，仅警告 |
| `warning: symbol value 'm' invalid for NF_CT_PROTO_GRE` | 该符号在 6.18 已由 tristate 变 bool，内核自动按 `=y` 处理 |
| `Pseudo file "dev" exists in source filesystem` | squashfs 打包时的设备节点提示 |
| 构建日志中出现 `internal error: len %d %% %d` | 那是源码里的字符串字面量，被 grep 误判为错误 |
| `CONFIG_KALLSYMS_UNCOMPRESSED=y` 无法关闭 | `include/kernel-defaults.mk:113` 硬编码写入 |
