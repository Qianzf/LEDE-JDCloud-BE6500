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
