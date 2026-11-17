# BE6500（JDCloud RE-CS-06 / IPQ5322）无线完整修复记录

> 本文是 `CHANGES.md` 第 7–16 节的**深度展开版**：把每一轮排查的过程、日志原文、实验方法、
> 被否决的方案都记下来，便于以后复现或向上游报 bug。
>
> 环境：OpenWrt 24.10.5 / Linux 6.18.62 / target `qualcommbe` `ipq53xx` / eMMC

---

## 目录

1. [硬件与软件模型（先看懂拓扑）](#1-硬件与软件模型)
2. [故障全景：一共 6 个独立故障](#2-故障全景)
3. [故障 1：TZ 拒绝 PAS_INIT_IMAGE（Q6 根本起不来）](#3-故障-1tz-拒绝-pas_init_image)
4. [故障 2：固件版本不一致（MLO 断言 + 重启循环）](#4-故障-2固件版本不一致)
5. [故障 3：校准数据开机时不存在](#5-故障-3校准数据开机时不存在)
6. [故障 4：2.4 GHz 因 HT 能力位缺失无法启动](#6-故障-42-4-ghz-max-amsdu)
7. [故障 5：保留内存布局与硬件不符](#7-故障-5保留内存布局)
8. [故障 6：LuCI 不显示 802.11k / 802.11v](#8-故障-6luci-不显示-80211k--v)
9. [诊断方法手册（可复用）](#9-诊断方法手册)
10. [错误码对照表](#10-错误码对照表)
11. [关键地址 / 偏移速查](#11-关键地址偏移速查)
12. [每轮构建的改动与结果](#12-每轮构建的改动与结果)
13. [遗留项与验证清单](#13-遗留项与验证清单)

---

## 1. 硬件与软件模型

### 1.1 两颗芯片组成一个 MLO 组

```
        IPQ5332 (SoC 内置射频, AHB 总线)          QCN9274 (独立芯片, PCIe)
        ───────────────────────────────         ─────────────────────────
        2.4 GHz 射频                             5 GHz / 6 GHz 射频
        remoteproc: q6wcss @ d100000              pci 0001:01:00.0
        固件: ath12k/IPQ5332/hw1.0/q6_fw0.mdt     固件: ath12k/QCN9274/hw2.0/firmware-N.bin
              + q6_fw1.mdt (UserPD)                    + board-2.bin
              + iu_fw.mdt
                    │                                     │
                    └──────── WSI（WLAN 串行接口）─────────┘
                        qcom,wsi-controller + ports 端点
                              ↓
                    一个逻辑 MLO 组（"WSI group 0"）
                              ↓
                     驱动里合成 **一个 wiphy（phy0）**
                        ├─ radio 0 → Band 1 (2.4 GHz)
                        └─ radio 1 → Band 2 (5 GHz)
```

### 1.2 为什么是"一个 phy 两个 radio"

- Wi-Fi 7 的 **MLO** 要求同一个 AP 把多条链路作为一个 **MLD** 呈现给客户端
- mac80211 里**一个 MLD 的 link 必须属于同一个 wiphy**（跨 wiphy 的 MLO 不支持 AP 模式）
- 所以驱动把两颗芯片的射频合并进一个 wiphy，OpenWrt 侧用 `option radio '0'/'1'` 选择

这条模型是后面故障 4（能力位）的根源，也是很多人误判的地方。

### 1.3 关键内核对象

| 对象 | sysfs / 命令 | 说明 |
|---|---|---|
| 无线硬件实例 | `/sys/class/ieee80211/phy0` | 本板只有 1 个 |
| 两个射频 | `iw phy phy0 info` → Band 1 / Band 2 | 分别对应 2.4G / 5G |
| 射频通路编号 | uci `option radio 'N'` | 0 / 1 |
| 虚拟接口 | `wlan0-0`、`wlan0-1` | AP 实例 |
| Q6 远程处理器 | `d100000.remoteproc` | 跑 2.4G 固件（+ 5G 的 WSI 主控） |
| PCI 无线设备 | `0001:01:00.0` | QCN9274 |

---

## 2. 故障全景

| # | 故障 | 现象 | 根因 | 修复 |
|---|---|---|---|---|
| 1 | TZ 拒绝 PAS_INIT_IMAGE | `error -5 initializing firmware q6_fw0.mdt`，Q6 rootPD 不启动 | 内核只发 v1 命令，TZ 固件要求 v2（带长度） | 内核补丁先发 v2（cmd `0x1a`），失败回退 v1 |
| 2 | 保留内存布局不符 | 安全世界 / WCSS 内存被内核占用 | DTS `tzapp` 地址错、wifi 保留区与硬件不符 | 对齐 VIKING 的 DTS（`tzapp@49b00000`、`q6_region` 48MB、去掉多余保留区） |
| 3 | 固件版本不一致 | `platform_mlo.c:2038` 断言、每 2-3 分钟重启 | IPQ5332 `1.7-01733` vs QCN9274 `1.6-01270` | 把 IPQ5332 降级到 `1.6-01270` |
| 4 | 校准数据缺失 | `qmi failed to load CAL data file` `-110` | 依赖 firmware hotplug 的 uevent 时机 | 新增 `S09ath12k-caldata` 开机预提取 |
| 5 | 2.4G HT 能力位缺失 | `Driver does not support configured HT capability [MAX-AMSDU-7935]` → `AP-DISABLED` | 驱动把 `HT_CAP_MAX_AMSDU` 挂在 VHT 能力字上 | 补丁 331：无条件置位 |
| 6 | LuCI 无 802.11k/v | 界面只有 802.11r | `wpad-basic` 无 EAP，LuCI 用 `hasSystemFeature('hostapd','eap')` 门控 | 换 `wpad-mbedtls` |

---

## 3. 故障 1：TZ 拒绝 PAS_INIT_IMAGE

### 3.1 现象

```
qcom-wcss-secure-pil: error -5 initializing firmware ath12k/IPQ5332/hw1.0/q6_fw0.mdt
qcom-wcss-secure-pil: RootPD boot failed
```

`-5` = `-EIO`，来自 `qcom_scm_remap_error(-1)`。

### 3.2 定位过程（ftrace）

在 `/sys/kernel/debug/tracing` 抓 `qcom_scm` 调用：

```
svc_id:0x02 cmd_id:0x01 args_cnt:2 args:{0xd, 0x7b108000}
    → res_to_callee:0xffffffffffffffff   (= -1)
    → -EIO(-5)
```

即：内核发的是 **`cmd_id=0x01`（PAS_INIT_IMAGE v1，2 个参数）**，TZ 直接返回 -1。

### 3.3 厂商内核反汇编（决定性证据）

从 eMMC 的 `mmcblk0p22`（HLOS_1）取出厂商内核（ARM32 Linux 5.4.213，加载基址 `0x40008000`），
反汇编 `qcom_scm_pas_init_image` 附近：

```
0x559714:  mov r2, #0x1a          ; cmd_id = 0x1a  ← v2
0x559718:  mov r3, #0x83          ; 3 个参数 (VAL, RW, VAL)
...
0x559770:  mov r2, #0x1           ; 回退：cmd_id = 0x1  (v1)
0x559774:  mov r3, #0xc           ; 2 个参数
```

符号表里也有 `qcom_scm_pas_init_image_v2`。

**结论**：TZ 固件（`QSEE`）要的是 **v2 协议（cmd `0x1a`，参数里带长度的散列 buffer）**，
内核只会发 v1，所以永远失败。

### 3.4 修复

```
target/linux/qualcommbe/patches-6.18/0900-firmware-qcom-scm-try-pas-init-v2.patch
```

逻辑：`qcom_scm_pas_init_image()` 先按 v2 发（3 个参数，含 `len`），失败则回退 v1，
保持对其它平台兼容。

### 3.5 验证

```
qcom_scm firmware:scm: pas init image v2: pas_id=13 len=11812 ret=0 res=0
qcom_scm firmware:scm: pas init image v2: pas_id=274 len=308 ret=0 res=0
remoteproc remoteproc0: remote processor q6wcss is now up
```

- `pas_id=13`：RootPD（`q6_fw0.mdt`，11812 字节）
- `pas_id=274`（0x112）：UserPD（`q6_fw1.mdt` / `iu_fw.mdt`）

---

## 4. 故障 2：固件版本不一致（MLO 断言 + 重启循环）

### 4.1 现象（build13 刷机后）

```
[73.0] ath12k_wifi7_ahb: fw_version ... WLAN.WBE.1.7-01733-QCAHKSWPL_SILICONZ-1   ← 2.4G
[73.5] ath12k_wifi7_pci: fw_version ... WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1   ← 5G/6G
[74.7] ath12k_wifi7_ahb: WSI group 0: MLO enabled for 2 devices
[76.1] qcom-wcss-secure-pil: fatal error received: err_smem_ver.2.1
       platform_mlo.c:2038 Assertion !partner_chip_crash_ind failed
       Image Variant : IMAGE_VARIANT_STRING=5332.wlanfw.evalQ
[76.2] remoteproc remoteproc0: crash detected in q6wcss: type fatal error
```

随后 phy0 虽然注册成功，但所有 WMI 命令失败：

```
failed to send WMI_SET_INIT_COUNTRY CMD :-108          (-108 = ESHUTDOWN)
failed to enable PMF QOS: -108
fail to start mac operations in pdev idx 0 ret -108
```

**并且整机每 2–3 分钟自动重启一次**：`/proc/sys/kernel/panic=3`，panic 后 3 秒自动重启，
重启后 76 秒又崩，形成自增强循环。这个循环还让构建连续失败两次：

```
fatal: unable to access 'https://git.openwrt.org/project/fstools.git/':
       Could not resolve host: git.openwrt.org
```

### 4.2 根因

MLO 协作要求组内双方**跑同一份固件构建**（协议结构体布局必须一致）。而 DD-WRT 固件包
（`ath-firmware-ddwrt`，commit `bd7c0abd`）里：

| 芯片 | 版本 |
|---|---|
| IPQ5332 | `WLAN.WBE.1.7-01733`（2026-09-30） |
| QCN9274 | `WLAN.WBE.1.6-01270`（2026-01-16） |

QCN9274 在 MLO 握手时上报 crash indication，IPQ5332 固件断言
`!partner_chip_crash_ind`（"我以为对端不可能崩"）失败 → Q6 fatal error。

对照 VIKINGYFY 的可用镜像（解包 rootfs 读 `fw_version.txt`）：

```
IPQ5332/hw1.0/fw_version.txt: WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1
QCN9274/hw2.0/fw_version.txt: WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1   ← 两边一致
```

### 4.3 修复

新增本地覆盖目录（不改上游下载源，避免动 `firmware.mk` 的 hash 表）：

```
package/firmware/ath-firmware-ddwrt/files/ath12k/IPQ5332/hw1.0/   42 个文件，8.1 MB
package/firmware/ath-firmware-ddwrt/Makefile                      Build/Prepare 末尾追加 $(CP)
```

```make
define Build/Prepare
	$(call Build/Prepare/Default)
	$(INSTALL_DIR) $(addprefix $(PKG_BUILD_DIR)/,$(sort $(FIRMWARE_DIRS)))
	$(FIRMWARE_INSTALL)
	$(if $(wildcard ./files/*),$(CP) ./files/. $(PKG_BUILD_DIR)/)
endef
```

**关键细节**：不覆盖 `board-2.bin`（本板 BDF 由 `ipq-wifi` 提供，尺寸 89,292 B）

### 4.4 验证

```
q6_fw0.mdt md5 = 250e1642000d54df6c13dabc08560949   （与 VIKING 逐字节一致）
fw_version.txt = WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1

启动后：
ath12k_wifi7_ahb: fw_version ... WLAN.WBE.1.6-01270
ath12k_wifi7_pci: fw_version ... WLAN.WBE.1.6-01270
crash detected 次数 = 0        ← 此前每次启动必崩 1 次
重启循环消失
```

---

## 5. 故障 3：校准数据开机时不存在

### 5.1 现象

```
ath12k_wifi7_ahb: qmi failed to load CAL data file: cal-ahb-c000000.wifi.bin
ath12k_wifi7_ahb: qmi failed to load calibrated data :-110     (-110 = ETIMEDOUT)
```

### 5.2 这两个文件从哪来

由 `/etc/hotplug.d/firmware/12-ath12k-caldata` 从 ART 分区提取：

| 目标文件 | 源分区 | 偏移 | 长度 | 结果大小 |
|---|---|---|---|---|
| `ath12k/IPQ5332/hw1.0/cal-ahb-c000000.wifi.bin` | `0:ART` = `/dev/mmcblk0p17` | `0x1000` | `0xf800` | 63,488 B |
| `ath12k/QCN9274/hw2.0/cal-pci-0001:01:00.0.bin` | `0:ART` | `0x58800` | `0x2d000` | 184,320 B |

提取实现（`/lib/functions/caldata.sh`）：

```sh
dd if=$source of=$target iflag=skip_bytes,fullblock bs=$count skip=$offset count=1
```

### 5.3 排查：脚本没问题，时机有问题

```sh
# 手动执行立即成功
FIRMWARE=ath12k/IPQ5332/hw1.0/cal-ahb-c000000.wifi.bin sh /etc/hotplug.d/firmware/12-ath12k-caldata
→ 生成 63,488 字节，md5 727516bf652b04e7490669d5d8fbe813

# 直接 dd 也正常
dd ... iflag=skip_bytes,fullblock bs=63488 skip=4096 count=1 → 1+0 records out
```

`find_mmc_part 0:ART` 返回正确的 `/dev/mmcblk0p17`，`board_name` 返回 `jdcloud,re-cs-06`，
所以**偏移、脚本、分区都正确** —— 唯一的问题是 hotplug 由 uevent 触发，
在高负载/慢 eMMC 上会晚于固件的 `request_firmware()`，固件等不到就超时（-110）。

### 5.4 修复

```
target/linux/qualcommbe/ipq53xx/base-files/etc/init.d/ath12k-caldata
```

```sh
#!/bin/sh /etc/rc.common
START=09        # 早于 S10boot（kmodloader 在这里加载 ath12k）
STOP=99

start() {
	local fw handler=/etc/hotplug.d/firmware/12-ath12k-caldata
	[ -x "$handler" ] || return 0

	for fw in \
		ath12k/IPQ5332/hw1.0/cal-ahb-c000000.wifi.bin \
		ath12k/QCN9274/hw2.0/cal-pci-0001:01:00.0.bin
	do
		[ -s "/lib/firmware/$fw" ] && continue
		FIRMWARE="$fw" sh "$handler" >/dev/null 2>&1
		[ -s "/lib/firmware/$fw" ] || rm -f "/lib/firmware/$fw"
	done
}
```

**设计要点**：不重写偏移逻辑，而是复用热插拔脚本 —— 这样其它板型（同一 target 下还有
gl-be9300 等）继续走各自的板型判断，不会因为写死偏移而误伤。

### 5.5 验证

```
/etc/rc.d/S09ath12k-caldata -> ../init.d/ath12k-caldata   （镜像里自动生成）
刷机后 /lib/firmware/ath12k/*/hw*/cal-*.bin 在首次启动即存在
dmesg 无 'failed to load CAL data file'
```

---

## 6. 故障 4：2.4 GHz MAX-AMSDU

### 6.1 现象（build14 刷机后，5G 正常，2.4G 无信号）

```
logread:
  Driver does not support configured HT capability [MAX-AMSDU-7935]
  wlan0-0: interface state COUNTRY_UPDATE->DISABLED
  wlan0-0: AP-DISABLED

iwinfo:
  wlan0-0  ESSID: "ASUS_2.4G"
           Mode: Master  Channel: unknown (unknown)  HT Mode: NOHT
           Tx-Power: 0 dBm
```

### 6.2 定位过程

1. **手动用真实配置跑 hostapd**（把生成的 conf 的 `interface=` 换成一个手工创建的 vif）：

```sh
iw phy phy0 interface add wlanT type __ap
sed 's/^interface=.*/interface=wlanT/' /var/run/hostapd-phy0.0.conf > /tmp/t2.conf
hostapd -dd /tmp/t2.conf
→ Driver does not support configured HT capability [MAX-AMSDU-7935]
→ wlanT: AP-DISABLED
```

2. **删掉这个能力位再试**：

```sh
sed -i 's/\[MAX-AMSDU-7935\]//' /tmp/t3.conf
hostapd -dd /tmp/t3.conf
→ wlanT: AP-ENABLED
iw dev wlanT info → channel 6 (2437 MHz), width: 20 MHz     ← 硬件完全正常
```

3. **对比两个 band 的能力位**：

```sh
iw phy phy0 info
  Band 1 (2.4G) Capabilities: 0x11e7     ← 无 0x800
  Band 2 (5G)   Capabilities: 0x19e7     ← 有 0x800
```

`0x800` 就是 `IEEE80211_HT_CAP_MAX_AMSDU`（HT capability bit 11）。

### 6.3 根因链

```
① 本板一个 wiphy 承载 2.4G + 5G 两个 band
        ↓
② OpenWrt wifi-scripts 把 iw 输出里所有 band 的 Capabilities 按位或
   0x11e7 | 0x19e7 = 0x19e7 （含 0x800）
        ↓
③ 生成的 hostapd conf 对每个 radio 都下发 ht_capab=[...][MAX-AMSDU-7935]
        ↓
④ hostapd 用 2.4G 自己那份 caps（0x11e7）校验 → 失败
        ↓
⑤ AP-DISABLED（2.4G 没有信号）
```

驱动侧源头（`backports-7.2/drivers/net/wireless/ath/ath12k/mac.c`
`ath12k_mac_setup_ht_cap()`）：

```c
if (ar_vht_cap & WMI_VHT_CAP_MAX_MPDU_LEN_MASK)      /* 2.4G 无 VHT → 恒 0 */
        ht_cap.cap |= IEEE80211_HT_CAP_MAX_AMSDU;
```

语义错位：**HT 的能力位被 VHT 的能力字门控**。

### 6.4 修复（补丁 331）

```
package/kernel/mac80211/patches-qualcommbe/ath12k/
    331-ath12k-advertise-max-amsdu-on-all-bands.patch
```

```diff
-	if (ar_vht_cap & WMI_VHT_CAP_MAX_MPDU_LEN_MASK)
-		ht_cap.cap |= IEEE80211_HT_CAP_MAX_AMSDU;
+	/* A-MSDUs up to 7935 bytes are supported on every band, including
+	 * 2.4 GHz HE-only radios which report no VHT capabilities at all.
+	 */
+	ht_cap.cap |= IEEE80211_HT_CAP_MAX_AMSDU;
```

安全性依据：

| 依据 | 说明 |
|---|---|
| 语义 | 该位表示"支持 7935 字节 A-MSDU"，是接收侧重组的**声明**，不是开关 |
| 硬件 | 5G 已在声明（0x19e7）；同一固件在 HE 模式下 2.4G 同样支持 7935（HE 上限 11454） |
| 影响面 | 只影响 hostapd 的能力校验；失败可一行回退 |
| 应用验证 | `patch -p1 --dry-run` → `Hunk #1 succeeded at 8427 (offset -1 lines)` |

### 6.5 被否决的方案

| 方案 | 实测结果 | 否决原因 |
|---|---|---|
| 改 `wifi-scripts`，按 band 取对应 `Capabilities:` | **WiFi 完全起不来**：`ubus call network.wireless status` 返回 `{}`，`iw dev` 无任何接口 | awk 逻辑单独测是对的（2.4G → `0x11ef`），但放进 netifd handler 后设备不再注册，原因未查明，撤回 |
| 让 2.4G 不声明该能力（去掉 `[MAX-AMSDU-7935]`） | 能起来 | 功能回退：2.4G 永远不用 7935 A-MSDU |

### 6.6 与 VIKINGYFY 仓库的对比（为什么"照抄"解决不了）

| 检查项 | VIKING 仓库 | 结论 |
|---|---|---|
| `wifi-scripts/.../mac80211.sh` | 与上游一字不差（同样按位或 + `MAX-AMSDU-7935`） | 他没修这里 |
| `patches/ath12k/*` 里 `MAX_AMSDU` | `git grep` 零命中 | 他没有驱动补丁 |
| hostapd / wpad 二进制 | 11 处 `does not support configured HT` 校验字符串都在 | 没放宽校验 |
| backports 版本 | 7.2（与我们相同） | 代码一致 |
| 固件 | 1.6-01270（我们已对齐） | 一致 |
| BDF `board-2.bin` | md5 `92e6f84a…` / `1b60c13f…` | 与我们**完全相同** |

所以他要么是**两个独立 phy**（每 phy 一个 band，天然不会触发按位或问题），
要么他那台的 2.4G 也是 NOHT 半残状态。无论如何，这是**上游对"单 wiphy 多 radio"
场景的缺陷**，必须自己修。

---

## 7. 故障 5：保留内存布局

（简报；细节见 `CHANGES.md` 第 7、8 节）

| 项 | 修复前 | 修复后 |
|---|---|---|
| `tzapp` | 与硬件不符，内核占到安全世界内存 | `tzapp@49b00000`，6 MB，`no-map` |
| `q6_region`（WCSS） | 尺寸/基址不符 | `0x4a900000`，48 MB（`0x3000000`） |
| `sbl` | — | `sbl@4a500000`，1 MB |
| WiFi 节点保留区 | 自定义 MLO/CALDB 保留窗口 | 全部删除，改由驱动按需 CMA 分配 |
| `CONFIG_CMA_SIZE_MBYTES` | 64 | **128** |

来自 DTB 的实际验证（从 `sysupgrade.bin` 的 FIT 里解出 DTB 后反编译）：

```
tzapp@49b00000       reg = <0x0 0x49b00000 0x0 0x600000>   no-map
wcss@4a900000        reg = <0x0 0x4a900000 0x0 0x3000000>  no-map
sbl@4a500000         reg = <0x0 0x4a500000 0x0 0x100000>   no-map
wifi@c000000         memory-region = <q6-region, host-ddr-mem>
                     fw-memory-mode = <0x01>, rx-skb-slab
wifi@0 (PCI)         fw-memory-mode = <0x01>, rx-skb-slab, 无 memory-region
```

---

## 8. 故障 6：LuCI 不显示 802.11k / 802.11v

### 现象

LuCI「接口配置 → WLAN 漫游」里只有 `802.11r 快速切换` 一个复选框。

### 根因

`/www/luci-static/resources/view/network/wireless.js:500`：

```js
if (hwtype == 'mac80211') {
    o = ss.taboption('roaming', form.Flag, 'ieee80211r', ...);   // 只要支持 11r 就显示

    if (L.hasSystemFeature('hostapd', 'eap')) {                 // ← 门槛
        o = ss.taboption('roaming', form.Flag, 'ieee80211k', ...);
        o = ss.taboption('roaming', form.Flag, 'ieee80211v', ...);
    }
}
```

设备装的是 `wpad-basic-mbedtls`（无 EAP）→ 整块不渲染。

**注意：802.11k 功能其实一直是开的**，只是界面不显示：

```
uci: wireless.default_radio0.ieee80211k='1'
生成的 /var/run/hostapd-phy0.*.conf: rrm_neighbor_report=1 / rrm_beacon_report=1
```

（hostapd 用 `rrm_*` 实现 802.11k；`ieee80211k=1` 由 OpenWrt `hostapd.sh` 翻译）

### 修复

```
target/linux/qualcommbe/Makefile:  wpad-basic-mbedtls → wpad-mbedtls
.config:                           CONFIG_PACKAGE_wpad-mbedtls=y
                                   CONFIG_DEFAULT_wpad-mbedtls=y
```

---

## 9. 诊断方法手册

### 9.1 分层定位：先看"哪一层"坏了

| 层次 | 看什么 | 典型结论 |
|---|---|---|
| TZ / SCM | `dmesg \| grep scm`、ftrace | PAS 被拒 → 故障 1 |
| remoteproc | `dmesg \| grep remoteproc`、`/sys/class/remoteproc/` | Q6 启动/崩溃 → 故障 2 |
| 驱动 probe | `dmesg \| grep ath12k` | 固件加载、内存分配、svc_rdy |
| 固件 WMI | `failed to send WMI_*` | -108 → 固件已死；-110 → 等数据超时 |
| cfg80211 | `ls /sys/class/ieee80211/`、`iw phy` | 有没有 phy / band |
| mac80211 / hostapd | `iwinfo`、`logread \| grep hostapd` | AP-DISABLED / 能力位不符 |
| 用户态配置 | `ubus call network.wireless status`、`uci show wireless` | 有没有接口、绑哪个网络 |

### 9.2 常用命令

```sh
# 无线电与能力
ls /sys/class/ieee80211/
iw phy phy0 info | grep -E "Band|Capabilities|Frequencies"
iw dev
iwinfo

# 驱动状态
dmesg | grep -iE "ath12k|remoteproc|qmi|qcom_scm"
lsmod | grep -E "ath12k|mac80211|cfg80211"
ls /sys/bus/pci/drivers/ath12k_wifi7_pci/ | grep 0001
ls /sys/bus/platform/drivers/ath12k_wifi7_ahb/ | grep c000000

# hostapd 真实失败原因（关键手段）
wifi down; killall hostapd
iw phy phy0 interface add wlanT type __ap; ip link set wlanT up
sed 's/^interface=.*/interface=wlanT/' /var/run/hostapd-phy0.0.conf > /tmp/t.conf
hostapd -dd /tmp/t.conf 2>&1 | tail -30

# 配置层
ubus call network.wireless status
uci show wireless
grep -E "^channel|^ht_capab|^ieee80211" /var/run/hostapd-phy0.*.conf
```

### 9.3 ftrace 抓 SCM 调用（故障 1 的关键手段）

```sh
cd /sys/kernel/debug/tracing
echo 0 > tracing_on
echo qcom_scm > set_ftrace_filter      # 或使用厂商内核里的 tracepoint
echo function > current_tracer
echo 1 > tracing_on; <触发操作>; echo 0 > tracing_on
cat trace | tail -40
```

看 `svc_id / cmd_id / args` 与 `res_to_callee` 即可判断是"参数错"还是"命令不支持"。

### 9.4 与厂商内核对照（最硬的证据）

```sh
# 从 eMMC 备份分区取出厂商内核
dd if=/dev/mmcblk0p22 of=/tmp/vkern.bin
# 识别架构与基址后反汇编目标函数
objdump -D -b binary -m arm --adjust-vma=0x40008000 /tmp/vkern.bin | \
    sed -n '/5597/,/5598/p'
```

### 9.5 与参考固件对照

```sh
# 解包别人能用的镜像
mkdir /tmp/vkroot && unsquashfs -d /tmp/vkroot /path/to/vk.bin   # 或直接从 FIT 取
# 比固件/配置/BDF
md5sum /tmp/vkroot/lib/firmware/ath12k/*/hw*/{board-2.bin,fw_version.txt}
```

本项目的关键结论（固件版本、BDF md5、hostapd 校验字符串、wifi-scripts 逻辑）
**全部来自这种对照**，比"猜"可靠得多。

---

## 10. 错误码对照表

| 码 | 名称 | 本项目中的含义 |
|---|---|---|
| `-1` | `EPERM`/`-1` | SCM 返回 `0xffffffff`：TZ 拒绝该命令（故障 1） |
| `-5` | `EIO` | `qcom_scm_remap_error(-1)` 的结果：PAS 初始化失败 |
| `-16` | `EBUSY` | ACS 扫描冲突（两个 vif 同时对同一 phy 做 offchannel 扫描） |
| `-19` | `ENODEV` | 接口不存在（手动跑 hostapd 时忘了先 `interface add`） |
| `-108` | `ESHUTDOWN` | 固件已崩溃/停止：`failed to send WMI_*`（故障 2） |
| `-110` | `ETIMEDOUT` | 等固件数据超时：cal 文件不存在（故障 3） |

---

## 11. 关键地址 / 偏移速查

### 11.1 保留内存（DTS）

| 区域 | 基址 | 长度 |
|---|---|---|
| `tzapp` | `0x49b00000` | 6 MB |
| `sbl` | `0x4a500000` | 1 MB |
| `wcss`（q6_region） | `0x4a900000` | 48 MB |
| host-ddr 视角偏移 | `0x00c00000` | — |

### 11.2 ART 分区（`0:ART` = `/dev/mmcblk0p17`，1 MB，1024 B 块）

| 内容 | 偏移 | 长度 |
|---|---|---|
| 2.4G（AHB）校准数据 | `0x1000` | `0xf800`（63,488 B） |
| 5G/6G（PCI）校准数据 | `0x58800` | `0x2d000`（184,320 B） |

### 11.3 分区表（eMMC）

| 分区 | 设备 | 用途 |
|---|---|---|
| p17 | `mmcblk0p17` | ART（校准数据） |
| p21/p22 | `mmcblk0p21/22` | HLOS / HLOS_1（内核，各 7 MiB） |
| p23/p24 | `mmcblk0p23/24` | rootfs / rootfs_1（各 2 GB） |
| p29 | `mmcblk0p29` | ext4 数据区 1.16 GB |

### 11.4 固件版本

| 芯片 | 可用版本 | 说明 |
|---|---|---|
| IPQ5332 | `WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1` | 必须与 QCN9274 一致 |
| QCN9274 | `WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1` | DD-WRT 包自带 |

`q6_fw0.mdt` md5 = `250e1642000d54df6c13dabc08560949`

---

## 12. 每轮构建的改动与结果

| 构建 | 主要改动 | 结果 |
|---|---|---|
| build7/8 | BDF `Build/Prepare`、国家码、802.11k、gettext 回退、sockaddr 补丁、BTF 关闭 | 能出镜像；刷机后 Q6 `error -5` |
| build10/13 | DTS tzapp/WCSS 对齐、CMA 128、ath12k 补丁集换成 VIKING 版、内核 PAS v2 补丁 | **Q6 启动成功**（`res=0`），但 cal 数据缺失 → `-110` |
| build14 | IPQ5332 固件降级到 1.6-01270；新增 `S09ath12k-caldata` | MLO 断言消失、无重启循环；**5G 正常、2.4G `AP-DISABLED`（MAX-AMSDU）** |
| build16 | 补丁 331（MAX-AMSDU 无条件置位） | 待刷机验证 2.4G |
| build17 | build16 + `wpad-mbedtls`（LuCI 显示 802.11k/v） | 待刷机验证 |

产物校验（供对照）：

| 构建 | sysupgrade.bin sha256 |
|---|---|
| build14 | `dfd02ca742893496dd8fd4d1ac34adfec4e13421c61cb28d6b36149fa4ef4bef` |
| build16 | `bf6ee4da3dae36133e4784c3901b8f8ed3ab003c7f2cb665ebaa0eaef4d19c94` |

---

## 13. 遗留项与验证清单

### 13.1 刷机后必须验证

```sh
# 1. 2.4G 的 HT 能力位应包含 0x800
iw phy phy0 info | sed -n '/Band 1/,/Band 2/p' | grep Capabilities

# 2. hostapd 不再报能力位错误
logread | grep -c "does not support configured HT"     # 期望 0

# 3. 2.4G 真正起来
iwinfo | grep -A1 wlan0-0       # 期望 Channel 6 + HT Mode: HE20

# 4. 客户端实测
#    手机连 2.4G → 拿 IP → ping 10.0.0.1 → 测速
```

### 13.2 已知遗留

| 项 | 状态 | 备注 |
|---|---|---|
| 三频（5.2+5.8 / 6 GHz） | 未展开 | `qcom,num-radios=<1>` 只暴露 2 band；国内 6 GHz 未开放 |
| ACS + 双 vif | 已知问题 | 两个 vif 同时 ACS 会 `-16 EBUSY`，建议配固定信道 |
| 2.4G A-MSDU 真实性 | 待实测 | 若打流异常，回退补丁 331 即可 |
| `products-sha256sums.txt` | 需更新 | 每次出包更新 |
| 内网 gitea（10.0.0.166:1005） | 不可达 | 恢复后补推 |
