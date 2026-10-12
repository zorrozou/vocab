# -*- coding: utf-8 -*-
"""edge-tts v2 端点运行时补丁（微软 2026-10 把 Read Aloud 从 v1 迁到 v2，旧端点握手 403）

上游 issue: rany2/edge-tts#490（2026-10-10 起全球爆发）。
v2 令牌算法为社区逆向重建（msedge.dll），与 Edge 155 实测一致：
最终 Sec-MS-GEC = <16 位 patent hash>-<64 位 SHA256>，且在原数据前加了微软版权字符串。

用法：import edge_tts 之后尽早调用 patch_edge_tts()（模块级一次即可）。
"""
from __future__ import annotations

import hashlib
import struct

MASK = 0xFFFFFFFF
# 注意：这个版权字符串是算法的一部分，删掉令牌就错（微软把版权声明混进了哈希输入）
COPYRIGHT = b"Copyright (C) Microsoft Corporation. All rights reserved."


def _u32(x: int) -> int:
    return x & MASK


def _rol16(x: int) -> int:
    x &= MASK
    return ((x << 16) | (x >> 16)) & MASK


def _words_le4_even(data: bytes) -> list[int]:
    padded = data + b"\x00" * ((-len(data)) % 4)
    if not padded:
        return []
    a = list(struct.unpack("<" + "I" * (len(padded) // 4), padded))
    if len(a) % 2:
        a.append(0)
    return a


def _cs64_word_swap(words: list[int], key_words: list[int]) -> tuple[int, int]:
    a, b = key_words[0] | 1, key_words[1] | 1
    acc = 0
    last = 0
    for x, y in zip(words[0::2], words[1::2]):
        t = _u32(_rol16(x) * 0xEF0569FB + x * a)
        t = _rol16(t)
        q = _u32(t * 0x76F50F34)
        q = _u32(_rol16(q) * 0xC3EFEA97 + q)
        acc = _u32(acc + q)
        t = _u32(_rol16(y) * 0xC31713DB + y * b)
        t = _rol16(t)
        q = _u32(t * 0x1881CE3C)
        last = _u32(_rol16(q) * 0x35BD1EC9 + q)
        acc = _u32(acc + last)
    return last, acc


def _cs64_reversible(words: list[int], key_words: list[int]) -> tuple[int, int]:
    a, b = key_words[0] | 1, key_words[1] | 1
    state = acc = 0
    for x, y in zip(words[0::2], words[1::2]):
        state = _u32((state + x) * a)
        for const in (0xCF98B111, 0x87085B9F, 0x12CEB96D, 0x257E1D83):
            state = _u32(_rol16(state) * const)
        t = _u32((y + state) * b)
        t = _u32(_rol16(t) * 0xA27416F5)
        t = _u32(_rol16(t) * 0xD38396FF)
        t = _rol16(t)
        acc = _u32(acc + state)
        state = _u32(_rol16(_u32(t * 0x7C932B89)) * 0xBFA49F69)
        acc = _u32(acc + state)
    return state, acc


def _patent_hash(data: bytes) -> tuple[str, str]:
    digest = hashlib.sha256(data).digest()
    data_words = _words_le4_even(data)
    digest_words = _words_le4_even(digest)
    a = _cs64_word_swap(data_words, digest_words)
    b = _cs64_reversible(data_words, digest_words)
    x = a[0] ^ b[0]
    y = a[1] ^ b[1]
    return struct.pack("<II", x, y).hex().upper(), digest.hex().upper()


def _gec_v2_from_ticks(ticks_100ns: int, speech_key: str) -> str:
    """v2 令牌：<16-hex patent hash>-<64-hex sha256>，输入=版权串+ticks+token"""
    cs64, sha = _patent_hash(COPYRIGHT + f"{ticks_100ns}".encode("ascii") + speech_key.encode("ascii"))
    return f"{cs64}-{sha}"


def patch_edge_tts():
    """把 edge_tts 切到 v2 端点 + v2 令牌。幂等，可反复调用。"""
    from edge_tts import constants, drm
    from edge_tts import communicate   # communicate 在导入时把常量按值拷贝进自己命名空间，必须双写

    # 1) 端点迁移：bing v1 → msedgeservices v2，认证参数名 TrustedClientToken → Ocp-Apim-Subscription-Key
    key = constants.TRUSTED_CLIENT_TOKEN
    wss_url = (
        "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1"
        f"?Ocp-Apim-Subscription-Key={key}"
    )
    voice_list = (
        "https://api.msedgeservices.com/tts/cognitiveservices/voices/list"
        f"?Ocp-Apim-Subscription-Key={key}"
    )
    constants.WSS_URL = wss_url
    constants.VOICE_LIST = voice_list

    # 2) 版本号对齐 Edge 155（服务端按 Sec-MS-GEC-Version 判定协议版本）
    constants.CHROMIUM_FULL_VERSION = "155.0.4283.45"
    constants.SEC_MS_GEC_VERSION = "2-155.0.4283.45"
    constants.WSS_HEADERS["User-Agent"] = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        " (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36 Edg/155.0.0.0"
    )

    # 3) communicate 模块命名空间同步（它 import 时按值拷贝了常量）
    communicate.WSS_URL = wss_url
    communicate.SEC_MS_GEC_VERSION = "2-155.0.4283.45"
    communicate.WSS_HEADERS.update(constants.WSS_HEADERS)

    # 3) 令牌算法换 v2（保留 edge_tts 自己的时钟偏移校正）
    @staticmethod
    def _generate_v2() -> str:
        ticks = drm.DRM.get_unix_timestamp()          # 秒（含 clock skew 校正）
        ticks += drm.WIN_EPOCH                        # Windows file time epoch
        ticks -= ticks % 300                          # 5 分钟窗口向下取整
        ticks *= drm.S_TO_NS / 100                    # 换成 100ns 单位
        return _gec_v2_from_ticks(int(ticks), key)

    drm.DRM.generate_sec_ms_gec = _generate_v2
