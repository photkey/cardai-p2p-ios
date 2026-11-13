# camstream/1 线协议

三端（Windows 控制端、Android、iOS）共用同一份线协议；任何字段名、字面量、字节序改动必须三端同步。
Windows 参考实现：`Windows/streaming/camstream.py`（纯标准库）。

- ALPN：`cardai/camstream/1`
- 传输：iroh 双向流（每条流独立；控制流一条，每组媒体一条）
- 字节序：全部大端

## 1. 控制帧

```
u32be length | UTF-8 JSON
```

- `length` 只计 JSON 字节数；单条上限 `1_048_576` 字节。
- JSON 顶层必须是对象，含 `type` 字段。
- 长度不符、超限、非 UTF-8 JSON → `BAD_MESSAGE`。

## 2. 媒体流

打开双向流后依次写入：组头一次，随后 `frame_count` 个帧（帧头 + payload 连续）。

### 组头（固定 18 字节 + config）

| 字段 | 类型 | 说明 |
|---|---|---|
| magic | 4 字节 | 固定 `CSG1` |
| version | u8 | 固定 `1` |
| flags | u8 | bit0 = keyframe（首帧 IDR），bit1 = epoch_start |
| epoch | u32be | 采集纪元；重连不重置 |
| group_seq | u32be | 组序号；同 epoch 内单调 +1 |
| frame_count | u16be | 本组帧数 |
| config_len | u16be | config 字节数 |
| config | bytes | HEVC 参数集 Annex-B（VPS/SPS/PPS），仅 epoch_start 组可空 |

### 帧（16 字节头 + payload）

| 字段 | 类型 | 说明 |
|---|---|---|
| frame_len | u32be | payload 字节数，**不含** 16 字节头 |
| frame_id | u32be | 全局帧号；断线重连不重置 |
| capture_utc_us | i64be | 采集时刻绝对 UTC 微秒（相机时间基换算后） |
| payload | bytes | Annex-B HEVC 访问单元 |

## 3. 控制消息

| type | 字段 |
|---|---|
| `hello` | `device_id, platform, app_version, room, token, capabilities{profiles[{width,height,fps}],encoder,timestamp_source,battery,thermal}` |
| `welcome` | `session_id, server_utc_us, heartbeat_ms` |
| `select_profile` | `request_id, width, height, fps, gop, bitrate_bps, epoch, request_idr` |
| `catalog` | `device_id, epoch, width, height, fps, gop, codec="hevc", timescale=90000, timestamp_source, config_b64` |
| `group_ack` | `epoch, group_seq, accepted, reason` |
| `stats` | `fps, bitrate_bps, buffer_bytes, dropped_groups, thermal, battery, rtt_us` |
| `time_probe` | `seq, t1_us` |
| `time_reply` | `seq, t1_us, t2_us, t3_us` |
| `set_policy` | `mode="realtime"\|"reliable", max_buffer_bytes, max_age_ms, request_idr` |
| `stop` | `reason` |
| `error` | `code, message` |

`timestamp_source` 取 `camera_pts` 或 `output_receipt`。
`platform` 取 `android` / `ios`。
重连时 `hello` 额外带 `resume=true, last_acked_group_seq`。

### 错误码

`AUTH_FAILED` `BAD_MESSAGE` `UNSUPPORTED_PROFILE` `BUFFER_OVERFLOW`
`CAMERA_ERROR` `ENCODER_ERROR` `DISCONNECTED` `INTERNAL`

## 4. 档位

| 档位 | width×height | fps | gop | bitrate_bps | epoch |
|---|---|---|---|---|---|
| 默认 | 1280×720 | 30 | 15 | 2_000_000 | 1 |
| 回退 | 1920×1080 | 30 | 15 | 4_000_000 | 1 |
| 高速 | 1280×720 | 120 / 240 | 60 | 8_000_000 / 16_000_000 | 1 |

不支持的高帧率档位回 `error UNSUPPORTED_PROFILE`，控制端保留 30fps。

## 5. 配对 URI

```
cardai://pair?ticket=<iroh ticket>&room=<room>&token=<token>&addr=<id@host:port,...>
```

- `ticket`：iroh `EndpointTicket` 字符串（Python/iOS 客户端直接解析）。
- `addr`：`<endpoint_id_hex>@<ip:port>,<ip:port>`；iroh 各语言绑定的 ticket 编解码存在
  版本斜杠（Android 1.2.0 拒绝 Python 1.2.0 生成的 ticket），手机端优先用该字段直接
  构造 `EndpointAddr`，缺失时回退解析 `ticket`。
- `token` 每次启动重新生成；房间号与 token 同时匹配才通过鉴权。

## 6. 会话顺序

```
手机                                     Windows
  |-- hello ---------------------------->|
  |<---------------------------- welcome -|
  |<----------------------- select_profile-|
  |-- catalog (控制流) ------------------>|
  |-- 媒体流 group 0 (CSG1 + frames) ---->|
  |<--------------------- group_ack -------|
  |-- time_probe ------------------------>|   ×4，用于时钟偏移
  |<------------------------ time_reply ---|
  |-- stats ----------------------------->|   每 1s
  |<------------------------- set_policy --|   录制开始 reliable / 结束 realtime
```

## 7. 示例

组头（720p IDR、epoch=1、group_seq=0、3 帧、config 12 字节）：

```
43 53 47 31 01 03 00 00 00 01 00 00 00 00 00 03 00 0c
00 00 00 01 40 01 0c 01 ff ff 01 60
```

`hello`：

```json
{"type":"hello","device_id":"android-3f2a","platform":"android","app_version":"1.0.0","room":"101","token":"…","capabilities":{"profiles":[{"width":1280,"height":720,"fps":30}],"encoder":"hevc","timestamp_source":"camera_pts","battery":87,"thermal":"nominal"}}
```

`group_ack`：

```json
{"type":"group_ack","epoch":1,"group_seq":0,"accepted":true,"reason":""}
```

`set_policy`（录制开始）：

```json
{"type":"set_policy","mode":"reliable","max_buffer_bytes":268435456,"max_age_ms":0,"request_idr":true}
```
