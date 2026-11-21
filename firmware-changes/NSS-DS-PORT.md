# PPE Direct Switch 驱动栈：设计、现状与移植方案

设备：JDCloud BE6500 / RE-CS-06（`qualcommbe` / `ipq53xx` / IPQ5332 + QCN9274）
源码树：`/workspace/code/lede`，内核 6.18.62，无线 `backports-7.2`
分支：`qca-nss-ds-stack`（`master` 保持 `375be58d0`）

> 图例：**〔事实〕** = 有代码/二进制/日志证据，标注路径；**〔推断〕** = 未验证的假设，必须验证后才可当结论。

---

## 1. 目标

让 **2.4G（AHB IPQ5332 上的 ath12k）** 也能用 PPE Direct Switch，即无线流量走
`WLAN MAC ↔ PPE/EDMA` 直连，不经过主机 CPU 与 mac80211 栈。

5G（PCI QCN9274）**当前已能工作**，但走的是我们自己实现的 DS 传输层。目标状态是两频段都用
QSDK 那一套（nss-dp + nss-ppe），因为它们由 PPE/EDMA 侧主导，不依赖 WMAC 固件配合。

---

## 2. 术语与角色

| 名词 | 含义 |
|---|---|
| **PPE** | Packet Processing Engine，硬件转发引擎（路由/NAT/桥接由它做） |
| **EDMA** | PPE 与 WLAN/以太网之间的 DMA 引擎，负责搬运与描述符环 |
| **DS / PPEDS** | Direct Switch：PPE 与 WLAN MAC 直接交换描述符，帧不进 CPU |
| **DS node** | 一个 DS 实例；DTS 里 `qcom,ppeds-num = <2>`，即 2.4G 一个、5G 一个 |
| **VP** | Virtual Port，PPE 侧的逻辑出口，每个 AP netdev 一个 |
| **ring** | 环形描述符队列，DS 用 4 条（见 §3） |

原厂 DTB 证据：`/tmp/fdt_*.dtb`（12 份样本）全部含 `qcom,ppeds-num=<0x02>`；
原厂模块 `/tmp/stockroot/lib/modules/5.4.213/{qca-nss-ppe-ds.ko,qca-nss-dp.ko,umac.ko}`。
〔事实〕

---

## 3. 数据面：四条通道（这是整个设计的核心）

DS 一旦建立，每个 DS node 有 4 条环。**方向定义必须记死**，否则后面全乱：

```
        ┌──────────────────── 下游 / 发往无线 (down) ────────────────────┐
        │                                                                │
   PPE ─┤ RXDESC 环 ──► EDMA ──► WLAN 的 TCL 环 ──► 射频发出            │
        │    (EDMA 生产, WLAN 消费)                                       │
        │                                                                │
        │ RxFill 环 ──► EDMA 取“空闲 TX buffer” ──► 供 RXDESC 使用        │
        │    (ath12k 生产, EDMA 消费)                                     │
        └────────────────────────────────────────────────────────────────┘

        ┌──────────────────── 上游 / 从无线收 (up) ──────────────────────┐
  射频 ──► WLAN 的 REO 环 ──► TXDESC 环（REO2PPE）──► EDMA ──► PPE 转发  │
        │    (WLAN 生产, EDMA 消费)                                       │
        │                                                                │
        │ TXCMPL 环（WBM2SW release）──► 回收 TX buffer 给 ath12k          │
        │    (EDMA 生产, ath12k 消费)                                     │
        └────────────────────────────────────────────────────────────────┘
```

### 3.1 四条环的对应关系〔事实〕

| 通道 | ath12k 侧（`dp_srng`） | 内核 PPE 驱动侧寄存器 | 描述符条目 |
|---|---|---|---|
| 下游描述符 | `HAL_PPE2TCL`（`ds->tcl`） | `EDMA_REG_RXDESC_PROD_IDX / RXDESC_CONS_IDX` | `hal_desc` PPE2TCL |
| 下游空闲 buffer | —（回调 `refill`） | `EDMA_REG_RXFILL_PROD_IDX / RXFILL_CONS_IDX` | `edma_rxfill_desc` |
| 上游描述符 | `HAL_REO2PPE`（`ds->reo`） | `EDMA_REG_TXDESC_PROD_IDX / TXDESC_CONS_IDX` | `hal_desc` REO2PPE |
| 上游完成 | `HAL_WBM2SW_RELEASE` ring 6（`ds->complete`） | `EDMA_REG_TXCMPL_PROD_IDX / TXCMPL_CONS_IDX` | `edma_txcmpl_desc` |

证据：`linux-6.18.62/drivers/net/ethernet/qualcomm/ppe/ppe_ds.c`
（`ppe_ds_sync_locked()` 约 225-292 行、`ppe_ds_refill()` 约 324-370 行、`ppe_ds_release()` 约 376-400 行）。
环大小：`ATH12K_DS_RING_ENTRIES 1024`、`ATH12K_DS_BUFFER_SIZE 2048`
（`ath12k/wifi7/ppe_ds.c:48,50`）。

### 3.2 索引同步协议〔事实〕

内核驱动在 NAPI 里跑 `ppe_ds_sync_locked()`，每次把两侧索引对齐：

```
读 ath12k 的消费/生产索引：
    tcl_cons = ops->get_tcl_cons(priv)      // WMAC 已消费到哪
    reo_prod = ops->get_reo_prod(priv)      // WMAC 已生产到哪
读 EDMA 自己的索引：
    rx_prod  = read(RXDESC_PROD_IDX)        // EDMA 已推了多少包给 WLAN
    tx_cons  = read(TXDESC_CONS_IDX)        // EDMA 已消费多少上游包

把 EDMA 的进度告诉 ath12k：
    ops->set_tcl_prod(priv, rx_prod)        // TCL 生产索引 = EDMA 进度
    ops->set_reo_cons(priv, tx_cons)        // REO 消费索引 = EDMA 进度

把 ath12k 的进度告诉 EDMA：
    write(RXDESC_CONS_IDX, tcl_cons)        // EDMA 可回收下游描述符
    write(TXDESC_PROD_IDX, reo_prod)        // EDMA 可投递上游描述符
```

计数器 `down_desc = (rx_prod - tcl_cons)`、`up_desc = (reo_prod - tx_cons)` 就是
debugfs 里看到的 `down_desc` / `up_desc`（`/sys/kernel/debug/ppe/direct_switch`）。

### 3.3 Buffer 所有权

- **TX buffer**（下游用）：ath12k 分配，存在 `ds->free_buffers` 池里，
  `refill` 时把 `{paddr, cookie=desc_id}` 交给 EDMA；上游完成时通过
  `release(cookies)` 归还并重新入池。〔事实：`ath12k_ds_refill()` / `ath12k_ds_release()`〕
- **RX 描述符**（上游用）：WMAC/REO 产生，`release` 路径按 `cookie` 反查
  `ath12k_rx_desc_info`（带 `ATH12K_DP_RX_DESC_MAGIC` 校验），防野指针。〔事实〕
- 池子用 `tx_lock`（TX 侧）与 `rx_lock`（RX 侧）分别保护，`control_lock` 序列化
  控制面（peer/VP 增删、停机、故障处理）。〔事实〕

### 3.4 启动序列（ath12k 侧，`ath12k_ds_start()`）〔事实〕

```
1. 读 HAL_REO1_DEST_RING_CTRL_IX_0，记下原来的 dest ring id（每 device_id 一次）
   改成 11（指向 PPE）
2. ath12k_dp_rx_htt_ds_cfg(ab)                   // HTT 层通知固件
3. 若 HAL_REO2PPE_DEST_INFO 存在（QCN9274 hw2.0 才有）写 DEST_INFO
4. TCL 的 RBM mapping 指向 HAL_WBM2SW_DS_RBM_ID
5. 最后才让 PPE 侧启动（自研：qcom_ppe_ds_start；QSDK：ppe_ds_wlan_instance_start）
```

顺序很重要：**先让 WMAC 侧就位，再启动 PPE 侧**，否则 EDMA 会在 WMAC 还没准备好时
就往 TCL 环里推包。

---

## 4. 控制面

| 环节 | ath12k 侧 | 说明 |
|---|---|---|
| 建环 | `ath12k_dp_srng_setup(HAL_PPE2TCL/HAL_REO2PPE/HAL_WBM2SW_RELEASE)` | 主机侧分配 ring 内存并配置 SRNG |
| 注册 | 自研：`qcom_ppe_ds_register(&config)`；QSDK：`ppe_ds_wlan_inst_alloc/register` | 把三条环的物理地址交给 PPE 侧 |
| 启动 | `ds_start()` | §3.4 |
| VP 分配 | 每个 AP netdev 一个 VP，`vp_alloc(handle, netdev)` | 得到 PPE 端口号 |
| 路由 | `vp_route(port, direct)` | direct=走 PPE，否则回 CPU |
| peer | `ath12k_ds_peer_update/disable` | 按 peer 授权/撤销 |
| 停机 | 先全部 VP 回 CPU → 关 REO → 等 head 写回 → 关 PPE 侧 → 关 TCL | `ath12k_ds_stop()` 路径 |
| 故障 | `ds->faulted` + workqueue 隔离，`quarantine` 后不再重建 | 防抖 |

---

## 5. 两种实现对照

### 5.1 自研（当前 5G 在用）

```
ath12k(wifi7/ppe_ds.c)  ←→  qcom-ppe.ko（内核，25204 行）
                             ├── ppe_ds.c     DS 传输层（环 + 索引 + 中断）
                             ├── edma*.c      EDMA 驱动
                             ├── ppe_vp.c     VP
                             └── ppe_*.c      PPE 硬件配置/流表/debugfs
```

接口是 `include/linux/soc/qcom/ppe-ds.h` 里的 `qcom_ppe_ds_*`。
**注意：这套是我们自己写的，不是原厂产物，也不是 QSDK 产物。**

### 5.2 QSDK（BE6500 移植在用）

```
ath12k(QSDK 版)  ←→  qca-nss-wifi-plugins.ko   （适配层）
                 ←→  qca-nss-ppe.ko            （DS/VP/PPE 配置）
                 ←→  qca-nss-dp.ko             （EDMA + netdev）
                 ←→  qca-ssdk.ko               （交换机/PHY）
```

`qca-nss-ppe` 把 DS 接口直接导出（`drv/ppe_ds/exports/ppe_ds_wlan.h` + `exports/nss_plugins.h`）〔事实〕：

```c
struct ppe_ds *ppe_ds_wlan_inst_alloc(struct ppe_ds_wlan_ops *ops, size_t priv_size);
bool  ppe_ds_wlan_inst_register_arch_mode_wifi7(struct ppe_ds *node, struct ppe_ds_wlan_arch_reg_info *info);
int   ppe_ds_wlan_instance_start(struct ppe_ds *node, struct ppe_ds_wlan_ctx_info_handle *hdl);
void  ppe_ds_wlan_instance_stop (struct ppe_ds *node, struct ppe_ds_wlan_ctx_info_handle *hdl);
void  ppe_ds_wlan_inst_free(struct ppe_ds *node);
ppe_vp_num_t ppe_ds_wlan_vp_alloc(struct ppe_ds *node, struct net_device *dev, struct ppe_vp_ai *vpai);
ppe_vp_status_t ppe_ds_wlan_vp_free(struct ppe_ds *node, ppe_vp_num_t vp);
void  ppe_ds_wlan_service_status_update(struct ppe_ds *node, bool enable);
void  ppe_ds_wlan_rx(struct ppe_ds *node, uint16_t reo_prod_idx);
uint32_t ppe_ds_get_node_id(struct ppe_ds *node);
/* 另有 ppe_vp_alloc / ppe_vp_free / ppe_vp_cfg_update 直接导出（nss-ppe 的 ppe_vp.c）*/
```

回调结构 `struct ppe_ds_wlan_ops`（10 个）与我们的 `qcom_ppe_ds_ops` **一一对应**〔事实〕：

| `qcom_ppe_ds_ops` | `ppe_ds_wlan_ops` |
|---|---|
| `refill(priv, buffers, count, size)` | `get_tx_desc_many(node, elem, num, size, headroom)` |
| `release(priv, cookies, count)` | `release_tx_desc_single(node, cookie)` / `release_rx_desc(node, arr, count)` |
| `get_tcl_cons` / `set_tcl_prod` / `get_reo_prod` / `set_reo_cons` | 同名 |
| `fault` / `more_reo` | `enable_tx_consume_intr` / `notify_napi_done` |
| — | `get_wlan_arch_mode()`（7=WiFi7, 8=WiFi8）|
| — | `vp_cfg_update(dev, vpui)`（**插件回调 ath12k**，不是 ath12k 调它）|

---

## 6. 为什么 2.4G 不一样（事实与推断分开）

### 6.1 〔事实〕

1. 我们的 `ath12k_wifi7_ds_setup()` 有 `hw_rev` 白名单，只放行 `QCN9274_HW10/HW20`，
   IPQ5332 被直接 `return 0`。（`ath12k/wifi7/ppe_ds.c`）
2. QCA 的 `wifi7/hw.c` 里 `ipq5332 hw1.0` 的 `.ds_support = false`；
   而 `ds_support` 唯一用途是 `ppe.c:759` 处 **AHB 的 PPEDS 中断注册**。
3. QCA 的 DS 环**也是 ath12k 主机侧分配**：`ath12k_ppeds_dp_srng_alloc()` →
   `ath12k_ppe_ds_dp_srng_alloc()` → `ath12k_dp_srng_alloc_aligned()`，**没有任何固件请求**；
   只从插件拿到 `ppe2tcl_start_idx` / `reo2ppe_start_idx`（EDMA 侧环索引）。
4. IPQ5332 的 `hw_ops = &qcn9274_ops`，其 `srng_config` 里 `[HAL_PPE2TCL]` 有定义；
   `ring_mask` 结构体里**没有** PPE 相关字段。
5. 我们的 5G DS 实测有效：8 秒内 `down_desc +1097`、`up_desc +830`，
   而 host 路径 `wlan0-1` tx 只 +1 帧。

### 6.2 〔推断，未验证〕

- **之前认为"IPQ5332 固件不给 DS ring"——这个说法没有证据支持**。
  由于 §6.1-3/4，QCA 也不向固件申请这些环，我们的 `ath12k_dp_srng_setup()`
  同样只是主机侧分配 + 写 SRNG 寄存器。
- 因此 2.4G 不工作的**真正原因尚未确定**；最可能就是被我们自己的
  `hw_rev` 白名单挡掉了（§6.1-1），从未放行测试过。
- QCA 设 `ds_support=false` 只说明他们没启用 AHB 的 PPEDS 中断路径，
  **不等于**硬件/固件不支持 DS。

> 结论：在换成 QSDK 栈之前，**放行 IPQ5332 并实测** 是一个成本极低、能证伪的步骤（见 §9.1）。
> 现在我们在做的接口移植（§8）即便成功，也仍需要这一步才能确认 2.4G DS 真的起来。

---

## 7. DTS 侧

`target/linux/qualcommbe/dts/ipq5332-qca-nss.dtsi`（被 `ipq5322-re-cs-06.dts` include）〔事实〕

```
edma@3ab00000   compatible "qcom,edma"，31 个中断，qcom,ppeds-num=<2>，
                qcom,ppeds-map=<1 1 1 1 0x20 0x08 2 2 2 2 0x28 0x08>
ess-uniphy@7a00000 / nss-ppe / dp1 / dp2
&qcom_ppe（上游 ethernet@3a000000）→ status="disabled"   避免两套 PPE 驱动抢硬件
```

---

## 8. 移植设计（907 补丁，进行中）

### 8.1 思路

**不动数据面骨架，只换接口层。** 理由：`906-00..05`（3452 行）已经把 QCA 的 DS 设计
在 7.2 ath12k 上实现并让 5G 跑通；它与 `ppe_ds_wlan_ops` 语义一一对应（§5.2）。
所以移植 = 把 12 处 `qcom_ppe_ds_*` 换成 `ppe_ds_wlan_*`，外加一层 node→ds 映射。

### 8.2 映射表（已实现）

| 原调用 | 改为 |
|---|---|
| `qcom_ppe_ds_available()` | `ath12k_ds_available()`（模块依赖保证，恒 true） |
| `qcom_ppe_ds_register(&config)` | `ppe_ds_wlan_inst_alloc()` + `ppe_ds_wlan_inst_register_arch_mode_wifi7()` |
| `qcom_ppe_ds_start/stop` | `ppe_ds_wlan_instance_start/stop(node, &ds->ctx)` |
| `qcom_ppe_ds_unregister` | `ppe_ds_wlan_inst_free(node)` + 清 node 表 |
| `qcom_ppe_ds_vp_alloc(h, dev)` | `ppe_ds_wlan_vp_alloc(h, dev, &vpai{usr_type=DS, net_dev_type=WIFI})` |
| `qcom_ppe_ds_vp_route(h, port, direct)` | `ppe_vp_cfg_update(port, &ui{usr_type=DS/NONE, update_flags=USR_TYPE})` |
| `qcom_ppe_ds_vp_free(h, port)` | `ppe_ds_wlan_vp_free(h, port)` |
| `qcom_ppe_ds_sync/refill_ready/detach` | 去掉（EDMA 自己驱动，无需外部催） |
| `qcom_ppe_ds_ops` 回调 | `ppe_ds_wlan_ops`，用 `ath12k_ds_by_node()` 反查 `ds` |

### 8.3 关键不变量

1. **ABI 必须逐字节一致**：`nss/` 下的 4 个头文件（`ppe_drv_port.h`、`ppe_vp_public.h`、
   `nss_plugins.h`、`ppe_ds_wlan.h`）是从 nss-ppe 源码**原样复制**，禁止手工简化结构体。
2. **索引所有权不变**：ath12k 只读 WMAC 的索引、只写自己那侧的；跨侧同步由 PPE 侧负责。
3. **启动顺序不变**：WMAC 就位 → PPE 侧启动。
4. **回滚单点**：删掉 907 补丁即回到 906 现状（5G DS 仍工作）。
5. 5G 与 2.4G 各自一个 node，互不影响；node id 由 `ppe_ds_get_node_id()` 给出。

### 8.4 当前状态

已完成：`nss/` 头文件入库、`ppe_ds.c` 全部改写（`grep qcom_ppe_ds_` 已无残留）、
`ds_setup()` 加入 `ATH12K_HW_IPQ5332_HW10` 与 `node_type`（AHB→2G，PCI→5G）。

**当前编译错误（下一个动作）**：

```
../nss/ppe_ds_wlan.h:13:10: fatal error: ppe_vp_public.h: No such file or directory
```

原因：`nss/` 内部互相用 `#include <...>` 引用，但没有把 `nss/` 加进头文件搜索路径。
修法（二选一，倾向 A）：

- **A**：`ath12k/Makefile` 加 `subdir-ccflags-y += -I$(srctree)/$(src)/nss`
- **B**：把 4 个头文件放进 `wifi7/` 同级目录并改相对包含（改动头部内容，不推荐）

---

## 9. 验证方法

### 9.1 先做的低成本验证（可证伪 §6.2）

在**旧实现**（自研传输 + 906）上放行 `IPQ5332`，只需一次编译 + 刷机：

```sh
dmesg | grep -i "Direct Switch"     # 期望出现两条（AHB + PCI）
ls /sys/kernel/debug/ath12k/*/direct_switch
ls /sys/kernel/debug/ppe/direct_switch    # 期望 node:0 node:1 都 running:1
```

- 若 AHB 也出现 → **2.4G DS 其实一直可用，问题只是白名单**，QSDK 栈可以不做
- 若失败 → 才需要 §8 的接口移植

### 9.2 移植后的判据

1. `dmesg`：两处 `native PPE Direct Switch rings registered`
2. `/sys/kernel/debug/ppe/direct_switch`：两个 node `running:1`，`refill_fail` 不增长
3. 2.4G 打流 8 秒：`down_desc`/`up_desc` 递增，而 `wlan0-0` 的 tx/rx 计数基本不动
   （判据来自 5G 实测：host 路径 8 秒只 +1 帧）
4. 反向验证：停掉流量后 `active_flows` 清空、无 `tx_dropped`/`bad_cookie` 增长

---

## 10. 已完成的其他工作（与 DS 无关，但同一分支上下文）

| 事项 | 结果 |
|---|---|
| LuCI 改无线配置不生效 | 根因修复：`hostapd_iface_conf_changed()` 只看 `config_id`/`num_bss`/ifname，SSID 变更检测不到 → `991-ap-restart-BSS-when-config-changed.patch`，提交 `17b541ca6`，**用户已实测验证** |
| 多 MAC 地址池 | 提交 `375be58d0`（920 系列 rebase，仅上下文偏移） |
| QSDK PPE 栈移植 | 21 个适配补丁，7 个模块全部 `EXIT=0`；提交 `1a9611b2c` |
| `tx_deferred` 含义 | 更正：是中断掩码策略计数器（`ppe_ds.c:466`），不是"帧回退 CPU" |

---

## 11. 误判与更正记录（避免重犯）

| 曾经的判断 | 更正 |
|---|---|
| "`tx_deferred` 表示帧回退到 CPU" | 错。中断掩码策略计数 |
| "开源里没有 DS 白名单" | 错。QCA 有 per-chip `.ds_support` |
| "IPQ5332 固件不给 PPE ring" | **无证据**。QCA 的环也是主机侧分配（§6.1-3） |
| "VP 模型是反的，要重写 600 行" | 部分错。插件里 `vp_cfg_update` 确实是回调，但 nss-ppe **另外直接导出** `ppe_vp_alloc/free/cfg_update`，我们的 VP 逻辑可保留 |
| "要搬 QCA 的 200 个文件" | 错。906 已经是移植结果，只需换接口层 |
| "等 QSDK 出 6.18 版本" | 不可能。wlan-open 全部 tag（含最新 `NHSS.QSDK.14.1.r3-00028-O`）只有 `backports-6.1-9a0dddfb3` |

被否掉的路线与证据：
- **内核降 6.6 + 整套抄 BE6500 移植**：那移植是把 `package/kernel/mac80211` 整个换成
  QSDK `feeds-wlan-open` + `wlan-open/backports-6.1-9a0dddfb3` + `wlan-open-extns`，
  内核锁 6.6（`native-6.6/prepare-qsdk-wlan-open.sh`、`package/kernel/mac80211/Makefile:46`）
- **用原厂闭源 `umac.ko`**：无源码、只跑 5.4.213、依赖闭源符号
- **把 QCA ath12k 整体从 6.1 移植到 6.18**：不必要（§11 第 5 条）

---

## 12. 参考路径

本地源码：
```
/tmp/qcaath      QSDK ath12k 全树（wlan-open cc4cc0e3，201 文件）
/tmp/qwlan       wlan-open 克隆
/tmp/nssppe      qca-nss-ppe（drv/ppe_ds/、drv/exports/ppe_ds_wlan.h、exports/nss_plugins.h）
/tmp/nssdp       qca-nss-dp
/tmp/nssplugins  qca_nss_wifi_plugins.c
/tmp/be6500port  第三方 BE6500 移植（HEAD 69deaa2）
```
原厂证据：`/tmp/stockroot/lib/modules/5.4.213/`、`/tmp/fdt_*.dtb`、`/tmp/vkern.bin`
工作副本：`build_dir/target-aarch64_cortex-a53_musl/linux-qualcommbe_ipq53xx/mac80211-regular/backports-7.2/drivers/net/wireless/ath/ath12k/`

分支状态：`qca-nss-ds-stack @ 1a9611b2c` + 未提交的 907 改动（`nss/` 头 + `ppe_ds.c` 改写）

---

## 13. 待办事项（按优先级）

### A. 进行中

- [ ] **全量编译**（`make -j4 V=w`，日志 `/tmp/full2.log`，起于 15:43）
  - [ ] `check-size 7168k` 是否通过（余量只有 ~47 KiB）
  - [ ] 记录最终 Image / FIT / sysupgrade 镜像大小
  - [ ] 确认 `undefined!` 数量仍为 0
  - [ ] 记下镜像路径与 md5

### B. 依赖循环（有证据才动手）

- [ ] 若出现 `WARNING: modpost: ... undefined!` 或某个 `.ko` 的 `depends=` 缺项：
  1. `package/kernel/qca-nss-dp/Makefile` 加 `PKG_BUILD_DEPENDS:=qca-ssdk qca-nss-ppe`，把编序钉成
     `ssdk → ppe → dp → ppe-ds → ppe-vp`
  2. 把导出头 + `Module.symvers` 的安装挪进 `Build/InstallDev`（现在是手工拷）
  3. 包级 `DEPENDS` 保持成环（opkg 全装，无害）
- [ ] **清除手工绕过**：`staging_dir/.../usr/share/{qca-nss-ppe,qca-ssdk}/*.symvers` 与
      `usr/include/qca-nss-dp/*` 是手工补的，clean 后不重现；要么固化成 `InstallDev`，要么删掉验证能否自洽

### C. 验证（关键，先做低成本的那个）

- [ ] **§9.1 前置验证**：旧实现（自研传输 + 906）放行 `ATH12K_HW_IPQ5332_HW10`，刷机看 AHB 是否也出现
      `direct switch`。若出现 → 说明 QSDK 栈其实不必要，可整体回退
- [ ] 新栈刷机验证：
  - [ ] `dmesg | grep -i "Direct Switch"` 出现两条（AHB + PCI）
  - [ ] `/sys/kernel/debug/ppe/direct_switch` 两个 node `running:1`，`refill_fail` 不涨
  - [ ] 2.4G 打流 8 秒：`down_desc`/`up_desc` 递增，而 `wlan0-0` tx/rx 基本不动
  - [ ] 5G 同上（`wlan0-1`）
  - [ ] 反证：停流后 `active_flows` 清空、`tx_dropped`/`bad_cookie` 不增长
- [ ] **有线网络**：nss-dp 栈完全没验证过，重点是 dp1/dp2 端口起不起、VLAN/桥接是否正常
- [ ] 内存/稳定性：长跑、重启、无线重载后能否重新建 DS

### D. 清理与决策

- [ ] 决定 `qcom-ppe.ko`（自研 PPE 驱动）去留：DTS 已禁用其节点，但模块还在编、占 322 KiB；
      去掉可省体积，也能避免两套 PPE 抢硬件
- [ ] 决定 `qca-nss-ecm` / `qca-nss-sfe` 是否启用（当前 `.config` 未选；ECM 会再加 2-3 MB）
- [ ] `.config` 新增的 8 个 `CONFIG_PACKAGE_kmod-qca-*` 需要同步到 CI 的 config（`code/LEDE-CI`）
- [ ] 文档补写：本次全量编译结果、循环依赖最终结论

### E. 已知的构建环境问题（不是代码问题）

- [ ] `libnl-tiny` 下载哈希不匹配（网络中断时触发）→ 临时用 `touch .prepared` 绕过；
      网络恢复后应 `make package/libs/libnl-tiny/clean` 重新拉一次
- [ ] `git.openwrt.org` DNS 曾解析失败过，构建前建议先确认网络

### F. 未做但相关

- [ ] `fullcone` 目前是标准 masquerade（`0`），与 DS 无关，用户未要求恢复
- [ ] 分支 `qca-nss-ds-stack` 已推送 `8e87129c1`；`master` 已推送 `375be58d0`

---

## 14. 有线（ethernet）静态核对结果

### 14.1 现有可用拓扑（旧固件实测）

```
switch@10 (qca,qca8386, DSA qca8k)
  port@0 cpu : ethernet=<&ppe_qca8386>, tag=qca_4b, 2500base-x, fixed-link 2500
  port@1..4  : sgmii + phy-handle qca8386_phy1..4  → lan1/lan2/lan3/wan
&qcom_ppe ethernet@3a000000 / port@1 (label "switch"): 2500base-x, pcs-handle=<&pcs0_ch0>
设备实测：switch UP、lan2/lan3 2500、wan 1000、驱动 qca8k
```

### 14.2 新栈必须补的 4 处（已改）

| # | 改动 | 文件 |
|---|---|---|
| 1 | `dp2` 加 label `nss_dp_switch`、`qcom,ppe-offload-disabled=<1>`、`phy-mode` 由 sgmii 改 2500base-x | `ipq5332-qca-nss.dtsi` |
| 2 | 新增 `ess-instance`：`ess-switch@3a000000`（ipq53xx，mac_mode=0xc）+ `ess-switch1@1`（qca8386/mdio，4 PHY） | 同上 |
| 3 | DSA CPU 口 `qca8386/port@0.ethernet`：`&ppe_qca8386`（已 disable）→ `&nss_dp_switch` | `ipq5332-common-qca8386.dtsi` |
| 4 | `ess-switch@3a000000` 的 `reg` 按 `#address-cells=2` 写成 `<0x0 0x3a000000 0x1000000>` | `ipq5332-qca-nss.dtsi` |

### 14.3 静态核对结论（逐项有据）

| 项 | 结论 | 依据 |
|---|---|---|
| `switch_mac_mode=0xc` | = `PORT_WRAPPER_SGMII_PLUS`（2.5G SGMII），与 2500 链路一致；`0xf`=`SGMII_CHANNEL0`(PCS0) | `ssdk_init.h` 枚举；`adpt_hppe_portctrl.c:3229` |
| 时钟表 | **必须 29 项且顺序与厂商 DTB 一致**（ssdk 按名字取）。nsscc id 14/21/33/32/13/12/30/29/34/31/15/18/22/25/35/36/37/38 与我们头文件完全相同 | `fdt_15.dtb`(AP-MI01.6) 解析 + `qcom,ipq5332-nsscc.h` |
| 复位表 | 19 项：`ppe_rst`→`NSS_CC_PPE_BCR`(17)、`uniphy0/1_soft_rst`→`GCC_UNIPHY0/1_BCR`(121/124)、XPCS→171/172，余为 nsscc ARES | 参考 DTB + `nsscc-ipq5332.c` `qcom_reset_map` |
| `port_scheduler_resource/config` | 可选，缺失只 `SSDK_ERROR` 后 return | `ssdk_dts.c:816/839` |
| `link-intr-gpio` | 可选，无则轮询。**不要乱抄 GPIO** | `ssdk_dts.c:1228-1230` |
| nss-dp 与 `phy-mode` | nss-dp 不解析 `phy-mode`，速率由 SSDK 的 `switch_mac_mode` 决定 | `nss_dp_main.c:868-990` |
| CPU 口速率 | 2500base-X（旧栈实测 lan2/lan3=2500） | 旧 DTS + 设备实测 |
| WAN | 在交换机 port4，不需要独立 dp1 | 设备实测 `wan@switch` |

### 14.4 静态验证覆盖不到的（必须真机）

- qca8k(DSA) 能否以 nss-dp netdev 为 conduit 正常收发
- SSDK 是否接受这套 bmp / PHY 地址（看 dmesg）
- `qca_4b` tag 与 nss-dp conduit 的兼容性

### 14.5 顺带修的构建问题

- **P1**：全量编译在 `package/install` 报 `cannot find dependency kmod-qca-nss-ppe-ds`，
  真因是 `bin/targets/*/*/packages/Packages` 索引过期（06:39），不是依赖声明错。
  出镜像前删掉 `Packages*` 让它重新生成即可（已加到构建流程）。
- **P3**：`qca-nss-dp` 加 `PKG_BUILD_DEPENDS:=qca-ssdk qca-nss-ppe`，把编序钉成
  `ssdk → ppe → dp → ppe-ds → ppe-vp`，消除包级循环依赖导致的编序不确定。

---

## 15. 第二轮静态分析（ath12k ↔ nss-ppe）

方法：把 `patches-qualcommbe/` 下的 build/subsys/ath/ath12k 全部补丁按 Makefile 顺序
应用到纯净 `backports-7.2`（0 失败），再逐行对照 `qca-nss-dp` / `qca-nss-ppe` 源码。

### 15.1 查出的 6 个致命缺陷（5 个已修、1 个已改配置）

| # | 缺陷 | 后果 | 证据 | 处理 |
|---|---|---|---|---|
| W1 | `refill` 要求 `size == 2048`，nss-dp 传 1856/1984（页池 1728） | 一个 buffer 都供不出，DS 全死 | `nss_dp_dev.h:92-99` | 改为 `size > 2048` 才拒绝 |
| W2 | 未预留 headroom（nss-dp 要 128+NET_IP_ALIGN≈130） | 载荷越界 / 帧头被覆盖 | `edma_ppeds.c:1135`、`edma_rx.h:16`；QCA `skb_reserve(headroom)` | 新增 `ATH12K_DS_HEADROOM 192` + 超限拒绝并告警 |
| W3 | `service_status_update(node, true)` 实际是**置 STOP 位**，热路径每次调用 | 服务一跑就停 | `edma_ppeds.c:1696` `set_bit(EDMA_PPEDS_SERVICE_STOP_BIT)` | 热路径删除；start 后 `false`、stop 前 `true` |
| W4 | 批量硬截断 32 | 每次 `edma_warn` + 补环慢 | `edma_ppeds.c:1156` | 改为循环填满 |
| W5 | 丢弃注册返回的 `ppe2tcl_start_idx`/`reo2ppe_start_idx` | WMAC 环与 PPE 环起始索引不一致 | QCA `wifi7/ppeds.c:429`；`ath12k_ds_start_indices()` | 注册后调用 |
| W6 | 默认**中断模式**，而中断模式要求 WLAN 侧 PPEDS 中断 | 索引同步无人驱动，RS 停死 | `ppe_ds_main.c:34`、`ppe_ds.c:547`；QCA `ath12k_hif_ppeds_irq_enable` | **改默认值为轮询模式**（`007-ppe-ds-default-to-polling-mode.patch`） |

轮询模式依据：`idx_mgmt_freq=32768` → hrtimer 周期约 30.5 µs，双向索引都在 `ppe_ds_timer`
里同步；nss-dp 侧在轮询模式下改用自己的 NAPI（`edma_ppeds.c:1005`），不依赖缺失的中断。

### 15.2 核对通过的项（不会崩的地方）

- vendored 4 个头与**实际编译的** nss-ppe `01fa40d7` 逐字节一致（仅 include 引号）
- 调用的 10 个符号全部 `EXPORT_SYMBOL`；`ath12k_wifi7.ko` 的 `depends=` 含 `qca-nss-ppe-ds/-vp`
- `desc_id` 为 `u32` → `release_tx_desc_single(u32 cookie)` 截断无损
- `get_wlan_arch_mode()` 返回 7 = `PPE_DS_WIFI_ARCH_MODE_WIFI7`
- 完成环 `HAL_WBM2SW_DS_RING_NUM=6` 与 QCA `HAL_WBM2SW_PPEDS_TX_CMPLN_RING_NUM=6` 一致
- `ppe_ds_wlan_rx()` 在轮询模式下由 hrtimer 覆盖，无需调用
- `dp_ppeds_node_id` nss-ppe 不读，填 node id 无害

### 15.3 有线静态核对（补充）

| 项 | 结论 |
|---|---|
| DSA 能否找到 nss-dp 作 conduit | ✅ `of_dev_node_match` 沿 parent 链匹配，nss-dp 有 `SET_NETDEV_DEV` |
| `qca_4b` tag | ✅ `net/dsa/tag_qca.c` 注册 |
| PHY 复位归属 | 我们只有 `phy-reset-gpios`（复数，qca8k 用）；ssdk 找单数 `phy-reset-gpio` → **刻意不加**，避免两驱动抢复位 |
| qca8k 与 ssdk 双重配置 PHY | ⚠️ 只能真机验证；参考移植也是两者共存 |
| `switch_lan_bmp=0x1e` | ssdk 视角把 WAN 当 LAN（DSA 负责 netdev），影响限于 PPE 内部流表 |

### 15.4 关键前提发现

QCA 的 DS 启用点（`wifi7/dp.c:687-694`）要求 `ab->hw_params->ds_support`，
而 `ipq5332 hw1.0` 是 `ds_support = false`（`wifi7/hw.c:1061`）。

- **QCA 自己的 ath12k 在 IPQ5332 上从不启用 PPEDS DS**
- 第三方 BE6500 移植**也未修改该标志**（其 DTS 的 `qcom,ppeds-num=<2>` 只配置 EDMA 节点）
- 我们的实现用自己的白名单放行了 IPQ5332 —— 这条路径**没有任何参考实现**，风险全自负

### 15.5 仍需真机确认

1. 轮询模式下 2.4G/5G 的 DS 能否真正建立并跑流量
2. `ath12k_ds_refill` 在 1856/1984 尺寸下的实际行为（buffer 池 2048 × 192 headroom）
3. `enable_tx_consume_intr` 空实现在轮询模式下是否真的无影响
4. qca8k 与 ssdk 同时配置 PHY 是否会导致链路抖动

---

## 16. 第三～五轮静态分析汇总（ath12k ↔ nss-ppe / 有线）

方法固定：把 `patches-qualcommbe/` 下 build/subsys/ath/.../ath12k 全部补丁按 Makefile
顺序应用到纯净 `backports-7.2`（每次都要求 **0 失败**），再逐行对照 qca-nss-dp /
qca-nss-ppe / QCA wlan-open 源码与参考 DTB。

### 16.1 无线：累计 9 个致命缺陷，全部已修

| # | 缺陷 | 后果 | 证据 | 修复 |
|---|---|---|---|---|
| W1 | `refill` 要求 `size == 2048` | nss-dp 传 1856/1984 → 一个 buffer 都不给 → DS 全死 | `nss_dp_dev.h:92-99` | 改为 `size > 2048` 才拒绝 |
| W2 | 未预留 headroom | 载荷越界（nss-dp 要 128+NET_IP_ALIGN≈130） | `edma_ppeds.c:1135`、`edma_rx.h:16` | `ATH12K_DS_HEADROOM 192` + 超限拒绝 |
| W3 | `service_status_update(node, true)` 实为置 STOP 位 | 服务一跑就停 | `edma_ppeds.c:1696` | 热路径删除；start 后 `false`、stop 前 `true` |
| W4 | 批量硬截断 32 | `edma_warn` 刷屏 + 补环慢 | `edma_ppeds.c:1156` | 循环填满 |
| W5 | 丢弃注册返回的 `ppe2tcl_start_idx`/`reo2ppe_start_idx` | WMAC 环与 PPE 环起始索引不一致 | QCA `wifi7/ppeds.c:429` | 注册后调 `ath12k_ds_start_indices()` |
| W6 | 默认中断模式但缺 WLAN 侧 PPEDS 中断 | 索引同步无人驱动 | `ppe_ds_main.c:34` | **模块默认改轮询**（补丁 007） |
| W7 | `vpai.core_mask = 0` | DS flow 走 `PPE_DRV_SC_VP_RPS` → **送 CPU，等于没直通** | `ppe_drv_flow.c:1245`、`ppe_vp.c:471` | 2G=0x2 / 5G=0x1（与 nss-ppe 默认一致） |
| W8 | 只带 `USR_TYPE` 的 cfg_update 被静默丢弃 | 路由回 CPU 从未生效 | `ppe_drv_vp.c:130-134`（用 core_mask 门控 user_type） | 同时带 `USR_TYPE\|CORE_MASK` |
| W9 | VP 表按自己的槽位索引 | 硬件表按 VP 号索引 → 表内容错位 | QCA `wifi7/hal.c:892` | 按 `port` 索引（写入/清除两处） |
| W10 | `release_tx_desc_single` 接到 RX 回收函数 | TX cookie 过不了 magic 校验 → `faulted` | `ath12k_ds_release()` | 改为空实现（TX buffer 由完成环回收） |

### 16.2 无线：验证通过的机制（不会再崩）

- 头文件 ABI 与实际编译的 nss-ppe `01fa40d7` 逐字节一致；10 个符号全部导出
- `desc_id` 为 u32 → cookie 截断无损；`wifi_arch_mode=7` 正确
- DS 三条环由 `ath12k_dp_srng_calculate_msi_group()` 路由到 **MSI group 0**，
  依赖 `dp->ds` 在建环前已赋值（`ds_setup` 顺序已核）
- 环 `max_size=0xfffff`，2048 不会被裁剪
- 完成环 `HAL_WBM2SW_DS_RING_NUM=6` == QCA `HAL_WBM2SW_PPEDS_TX_CMPLN_RING_NUM`
- REO 目的环映射 `bits[27:24]=11` == QCA `REO2PPE_DST_RING_MAP`
- peer WMI 结构 `{tlv, mac, routing, service_code, priority_valid, src_info, vdev_id}`
  与 QCA 逐字段一致；取值 0/1/2 对应 QCA 枚举
- VP 表位布局 `7:0=VP_NUM, 9:8=PMAC(3), 15:10=BANK, 23:16=VDEV` 与 QCA 一致
- TX 描述符池 32768，DS 占 2048（≈6%），不会饿死普通 TX
- DS 初始化失败只 `ath12k_warn`，不影响 WiFi 起来；失败清理会 `dp->ds = NULL`
- `ath12k_ds_tcl_cons()` 读硬件写回地址，摘流循环不会死等
- 轮询模式下 RxFill 中断由 nss-dp 无条件申请，补环正常

### 16.3 无线：仍需真机确认

1. 轮询模式 hrtimer 与我们的回调是否真正配合
2. **VP 所有权模型差异**：QSDK 由外部（nss-dp/ECM）建 VP，ath12k 只 `get_vp_num()` 查；
   我们自己 `ppe_vp_alloc()`。未启用 ECM 时我们是唯一来源，将来启用 ECM 需重新设计
3. 2.4G（IPQ5332）DS 能否建立 —— **QCA 自己从不启用**（`ds_support=false`），无参考实现

### 16.4 有线：12 项核对，11 通过

| 项 | 结论 |
|---|---|
| DSA conduit 解析 | ✅ `of_dev_node_match` 沿 parent 链匹配，nss-dp 有 `SET_NETDEV_DEV` |
| `qca_4b` tag | ✅ `net/dsa/tag_qca.c` 注册 |
| `ess-instance`/`ess-switch`/`ess-switch1` | ✅ 命名与 ssdk 的 `of_find_node_by_name` 对齐 |
| 29 时钟 / 19 复位 | ✅ 名字与顺序同厂商 DTB；每个 id 在 `gcc-ipq5332.c`/`nsscc-ipq5332.c` 均有注册 |
| `port_scheduler_*` | ✅ 可选（缺失只 `SSDK_ERROR` 后 return） |
| `link-intr-gpio` | ✅ 可选；我们**刻意不填**，改 polling |
| `phy-reset-gpio`（单数） | ✅ 我们只有复数版（qca8k 用），ssdk 不复位 PHY，避免两驱动抢 |
| PHY 是否在主 mdio | ✅ `__of_mdiobus_parse_phys()` 递归进 `ethernet-phy-package` 把子 PHY 注册到同一总线 → addr 1-4 可访问 |
| `&qcom_ppe` 覆盖顺序 | ✅ include 顺序使 `status="disabled"` 生效 |
| `ess-uniphy`/`nss-ppe`/`ppeds-map` | ✅ 与参考 DTB 逐值相同 |
| `IPQ_NSSCC_QCA8K` | ✅ 实际配置 `=y`（target config 那行被覆盖） |
| **qca8k 与 ssdk 双 owner PHY** | ⚠️ 只能真机验证 |
