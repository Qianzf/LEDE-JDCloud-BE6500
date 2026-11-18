# JDCloud BE6500 固件（LEDE / OpenWrt）

基于 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) 为 **JDCloud RE-CS-06 / BE6500** 定制的固件源码。

> **纯 AI 项目，零手工。** 这套固件（含设备支持、DTS、驱动补丁、默认配置、CI 流水线）
> 全部由 AI 编写、修改和验证，没有任何一行是手工抄改出来的；发现问题也是靠日志和
> 源码定位后直接改源码，不靠改设备配置糊过去。

## 设备

| 项 | 值 |
|---|---|
| 型号 | JDCloud RE-CS-06 / BE6500 |
| 平台 | Qualcomm `qualcommbe` / `ipq53xx` |
| SoC | IPQ5322（4×A53 aarch64，musl） |
| 无线 | QCN6224，Wi-Fi 7（802.11be）双频 4×4 |
| 存储 | eMMC，UBI + squashfs |
| 内核 | Linux 6.18 |
| 镜像 | `squashfs-sysupgrade`（保留配置升级）/ `squashfs-factory`（整机写入），约 150 MB |

## 出厂默认

- 管理地址 `192.168.1.1`，LuCI 中文界面，主题 **Vantage**
- 主机名 `JDCloud`，时区 `CST-8` / `Asia/Shanghai`，国家码 `CN`
- 默认 SSID：2.4G `JDCwifi`、5G `JDCwifi-5G`（**仅出厂默认**，升级不会覆盖你自己设的名字）

## 已启用的模块

**网络 / 代理**

- `passwall2`、`homeproxy`、`ssr-plus`、`openclash`、`gecoosac`
- `smartdns`、`ddns-scripts`、`fullconenat`、`natmapt`、`dcwapd`、`arpbind`

**服务 / 存储**

- Docker（`docker` + `dockerd` + `containerd`）
- `samba4`、`vsftpd`、`mini-diskmanager`、`partexp`
- `lucky`、`ttyd`、`vlmcsd`、`wolplus`（网络唤醒）

**监控 / 运维**

- `nlbwmon` 流量统计、`statistics`、`upnp`、`autoreboot`、`commands`、`filetransfer`
- `package-manager`、`oui`

**界面**

- `luci-theme-vantage` + 中文语言包，`luci-i18n-base-zh-cn`

## 支持程度

**可用**：日常路由 / NAT 加速 / Wi-Fi 7 双频 4×4（2.4G HE20、5G EHT80/EHT160）/
Docker / 上述全部插件。

**已修复的坑**

| 问题 | 原因 | 处理 |
|---|---|---|
| Wi-Fi 出不了信号 | 频段能力位在上游被裁掉，驱动不下发 band caps | 补丁改回 `0x19e7`，2.4G/5G 正常起 BSS |
| 启动卡住 ~60 秒 | `ath12k` 先试 `firmware-2.bin`，IPQ5332 上没有这个文件，`request_firmware()` 干等 60 s 超时 | 补丁 919：改走 `request_firmware_direct()`，缺失立即返回（8.824 s → 8.832 s） |
| 部分设备搜不到 5G | `channel=auto` 时脚本把 `acs_survey` 当 0 算中心频点，得到 `seg0=-6`（`center_freq1=4970MHz`），DFS 判定失败；ACS 还会选到 DFS 信道 | `mac80211.sh`：ACS 不写 seg0，交给 hostapd 选完信道再算；`acs_exclude_dfs` 默认开 |
| 升级后 SSID 被改回默认 | 用 uci-defaults 脚本设 SSID，而它每次 sysupgrade 都会再跑一遍 | 删掉该脚本，改在 `lib/wifi/mac80211.sh` 的"生成默认配置"分支里给默认值 |

**已知限制**

- 5G 用 **160 MHz** 时，带宽会跨到 DFS 频段，开机需 CAC 60–90 秒，期间搜不到；
  用 EHT80 + 非 DFS 信道则无此问题（ACS 已默认排除 DFS）。
- 频率相关行为受客户端国家码影响，不同设备可见信道不同，属正常现象。
- 驱动里保留了 `ATH_DEBUG` 便于现场抓日志，但 `debug_mask` 默认为 0，不产生额外开销。

## 自行编译

```bash
git clone https://github.com/Qianzf/LEDE-JDCloud-BE6500.git
cd LEDE-JDCloud-BE6500
./scripts/feeds update -a && ./scripts/feeds install -a
cp .config.example .config 2>/dev/null || true   # 或从 CI 仓库取 config/jdcloud-be6500.config
make defconfig && make -j$(nproc) V=w
```

产物在 `bin/targets/qualcommbe/ipq53xx/`。

也可用配套的 GitHub Actions 流水线出包：[Qianzf/LEDE-CI](https://github.com/Qianzf/LEDE-CI)。

## 说明

- 本项目只是上述 LEDE 源码的一个定制分支，遵循其原始许可证（GPL-2.0）。
- 刷机有风险，自担；`factory` 镜像会重写 UBI，务必确认机型相符。
