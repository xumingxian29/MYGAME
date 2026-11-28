#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成《暗夜幸存者》的全部音效，输出到 assets/audio/*.wav。

为什么用合成的而不是找素材：
  1. 项目没有音频资源，加素材要管授权，合成则完全自有；
  2. 体积可控：14 个音效合计 ~330KB，Web 首包能接受；
  3. 音色能按事件调——"命中"要短到听不出音高，"Boss 出场"要有次低频。

采样率 22050 单声道 16bit：游戏音效的高频细节不重要，22k 比 44.1k 省一半体积，
而且纯 Python 逐样本合成也不慢（全部 14 个不到 1 秒）。

设计约定（改音效时守住这几条，否则会变成一串"哔哔"声）：
  · 打击类（shoot/hit/kill）必须有噪声成分，纯正弦没有冲击感
  · 有方向的（pickup 上滑 / dead 下滑 / skill 上扫）用频率扫描表达，不靠调音量
  · 每个音都要有起音衰减的包络，突然截断会有咔哒声（结尾留 5ms 淡出）
  · 削波用 tanh 软限幅，硬 clip 会产生刺耳的高频谐波

用法：python dev/gen_sfx.py
"""
import math
import os
import random
import struct
import wave

RATE = 22050
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")
TAU = math.pi * 2.0
_rng = random.Random(20261125)


# ---------------------------------------------------------------- 基础工具

def env_ad(t: float, dur: float, attack: float, curve: float) -> float:
    """起音 + 指数衰减包络。attack 是线性起音时长（秒），curve 控制衰减陡度。"""
    if t < attack:
        return t / attack
    return math.exp(-(t - attack) * curve)


def sweep(t: float, dur: float, f0: float, f1: float, curve: float = 1.0) -> float:
    """频率从 f0 线性/指数扫到 f1，返回当前相位增量对应的瞬时频率。"""
    p = min(t / dur, 1.0)
    return f0 * math.pow(f1 / f0, p ** curve)


def lowpass(samples, cutoff: float):
    """一阶 IIR 低通。用来把噪声磨得不刺耳。"""
    rc = 1.0 / (TAU * cutoff)
    dt = 1.0 / RATE
    a = dt / (rc + dt)
    out = []
    prev = samples[0] if samples else 0.0
    for x in samples:
        prev = prev + a * (x - prev)
        out.append(prev)
    return out


def highpass(samples, cutoff: float):
    """一阶高通。去掉低频"闷"感，让 click 类音效更利。"""
    rc = 1.0 / (TAU * cutoff)
    dt = 1.0 / RATE
    a = rc / (rc + dt)
    out = []
    prev_x = samples[0] if samples else 0.0
    prev_y = 0.0
    for x in samples:
        y = a * (prev_y + x - prev_x)
        out.append(y)
        prev_x = x
        prev_y = y
    return out


def finish(samples, peak: float = 0.82, fade_ms: float = 6.0):
    """归一化 + 软削波 + 尾部淡出。任何音效写盘前都要过这一道。"""
    n = len(samples)
    if n == 0:
        return samples
    top = max(abs(x) for x in samples) or 1.0
    out = []
    for x in samples:
        v = x / top * peak
        # tanh 软限幅：超过 ±1 的部分被压弯而不是直接切平，避免刺耳谐波
        out.append(math.tanh(v * 1.15) / math.tanh(1.15))
    # 尾部 6ms 淡出，防止波形突然归零产生咔哒
    fade_n = min(int(RATE * fade_ms / 1000.0), n)
    for i in range(fade_n):
        out[n - fade_n + i] *= (fade_n - i) / fade_n
    return out


def write_wav(name: str, samples):
    path = os.path.join(OUT_DIR, name + ".wav")
    frames = bytearray()
    for v in samples:
        frames += struct.pack("<h", max(-32767, min(32767, int(v * 32767))))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))
    kb = len(frames) / 1024.0
    print("  %-10s %6.2fs  %5.0f KB" % (name, len(samples) / RATE, kb))


def gen(dur: float, fn):
    n = int(RATE * dur)
    return [fn(i / RATE, dur) for i in range(n)]


# ---------------------------------------------------------------- 单个音效

def sfx_shoot():
    """开火：噪声爆发 + 轻微下扫。极短（80ms），高密度下必须听不出音高。"""
    dur = 0.08

    def f(t, d):
        n = _rng.uniform(-1.0, 1.0)
        body = math.sin(TAU * sweep(t, d, 340.0, 190.0) * t)
        return (n * 0.75 + body * 0.35) * env_ad(t, d, 0.001, 95.0)

    return finish(lowpass(gen(dur, f), 4200.0), 0.55)


def sfx_hit():
    """命中：30ms 极短 click。这是全游戏最频繁的音效，短到几乎只剩"嗒"才不糊。"""
    dur = 0.045

    def f(t, d):
        n = _rng.uniform(-1.0, 1.0)
        tone = math.sin(TAU * 1450.0 * t)
        return (n * 0.6 + tone * 0.5) * env_ad(t, d, 0.0008, 150.0)

    return finish(highpass(lowpass(gen(dur, f), 6500.0), 400.0), 0.5)


def sfx_kill():
    """击杀：短碎裂。比命中长一倍、带下行，听得出"这东西没了"。"""
    dur = 0.13

    def f(t, d):
        n = _rng.uniform(-1.0, 1.0)
        tone = math.sin(TAU * sweep(t, d, 620.0, 160.0) * t)
        return (n * 0.7 + tone * 0.45) * env_ad(t, d, 0.002, 38.0)

    return finish(lowpass(gen(dur, f), 3800.0), 0.62)


def sfx_hurt():
    """受伤：低频冲击。这是玩家必须立刻察觉的音，做厚、做低。"""
    dur = 0.28

    def f(t, d):
        thump = math.sin(TAU * sweep(t, d, 150.0, 52.0, 1.6) * t)
        n = _rng.uniform(-1.0, 1.0) * math.exp(-t * 22.0)
        return (thump * 0.95 + n * 0.35) * env_ad(t, d, 0.003, 12.0)

    return finish(lowpass(gen(dur, f), 1300.0), 0.88)


def sfx_pickup():
    """拾取经验：上滑"叮"。上滑=获得，这是不需要教就能懂的方向感。"""
    dur = 0.08

    def f(t, d):
        freq = sweep(t, d, 880.0, 1420.0, 0.7)
        tone = math.sin(TAU * freq * t) + 0.3 * math.sin(TAU * freq * 2.0 * t)
        return tone * env_ad(t, d, 0.002, 42.0)

    return finish(gen(dur, f), 0.45)


def sfx_levelup():
    """升级：四音上行琶音（C5-E5-G5-C6）。唯一允许"好听"的音效，它是奖励。"""
    dur = 0.52
    notes = [523.25, 659.25, 783.99, 1046.5]
    step = 0.085

    def f(t, d):
        total = 0.0
        for i, hz in enumerate(notes):
            start = i * step
            if t < start:
                continue
            lt = t - start
            e = math.exp(-lt * 7.5)
            total += (math.sin(TAU * hz * lt) + 0.25 * math.sin(TAU * hz * 2.0 * lt)) * e
        return total * 0.5

    return finish(gen(dur, f), 0.62)


def sfx_card():
    """选卡确认：双击感。不放进一个和弦，是因为它要跟"升级"区分开。"""
    dur = 0.16

    def f(t, d):
        v = 0.0
        for start in (0.0, 0.07):
            lt = t - start
            if lt < 0.0:
                continue
            v += math.sin(TAU * 980.0 * lt) * math.exp(-lt * 55.0)
        return v * 0.6

    return finish(gen(dur, f), 0.5)


def sfx_skill():
    """技能释放：低频上扫 + 噪声尾。扫频方向=能量释放，和拾取的上滑区分在更低更厚。"""
    dur = 0.34

    def f(t, d):
        freq = sweep(t, d, 180.0, 880.0, 0.8)
        tone = math.sin(TAU * freq * t) * 0.8 + math.sin(TAU * freq * 1.5 * t) * 0.25
        n = _rng.uniform(-1.0, 1.0) * 0.45 * math.exp(-t * 9.0)
        return (tone + n) * env_ad(t, d, 0.02, 7.0)

    return finish(lowpass(gen(dur, f), 5200.0), 0.7)


def sfx_boss_in():
    """Boss 出场：次低频轰鸣。40Hz 在手机上几乎听不到，但会"感觉到"。"""
    dur = 0.85

    def f(t, d):
        sub = math.sin(TAU * sweep(t, d, 62.0, 34.0, 1.2) * t)
        grow = math.sin(TAU * 110.0 * t) * 0.3
        n = _rng.uniform(-1.0, 1.0) * 0.5 * math.exp(-t * 4.0)
        e = env_ad(t, d, 0.08, 4.2)
        return (sub * 1.0 + grow + n) * e

    return finish(lowpass(gen(dur, f), 900.0), 0.92)


def sfx_boss_die():
    """Boss 死亡：长爆破。要让玩家确认"这一关过了"，所以给足 0.6 秒。"""
    dur = 0.62

    def f(t, d):
        n = _rng.uniform(-1.0, 1.0) * math.exp(-t * 5.5)
        sub = math.sin(TAU * sweep(t, d, 180.0, 40.0, 1.4) * t) * math.exp(-t * 4.0)
        return (n * 0.9 + sub * 0.8) * env_ad(t, d, 0.004, 2.6)

    return finish(lowpass(gen(dur, f), 3000.0), 0.85)


def sfx_zone():
    """圈外警告：低频脉冲。会按间隔重复播放，所以必须短、必须不刺耳。"""
    dur = 0.2

    def f(t, d):
        tone = math.sin(TAU * 96.0 * t) + 0.4 * math.sin(TAU * 192.0 * t)
        return tone * env_ad(t, d, 0.012, 15.0)

    return finish(lowpass(gen(dur, f), 1100.0), 0.6)


def sfx_dead():
    """死亡：长下行。从 440 掉到 90，配合结算画面。"""
    dur = 0.9

    def f(t, d):
        freq = sweep(t, d, 440.0, 88.0, 1.3)
        tone = math.sin(TAU * freq * t) + 0.3 * math.sin(TAU * freq * 0.5 * t)
        return tone * env_ad(t, d, 0.01, 3.0)

    return finish(gen(dur, f), 0.7)


def sfx_clear():
    """章节通关：大三和弦上扬。比升级更长更宽，因为它要盖过战斗噪音。"""
    dur = 0.7
    notes = [523.25, 659.25, 783.99, 1046.5]

    def f(t, d):
        v = 0.0
        for i, hz in enumerate(notes):
            lt = t - i * 0.045
            if lt < 0.0:
                continue
            e = math.exp(-lt * 3.4) * min(1.0, lt / 0.012)
            v += (math.sin(TAU * hz * lt) + 0.3 * math.sin(TAU * hz * 2.0 * lt)) * e
        return v * 0.42

    return finish(gen(dur, f), 0.7)


def sfx_ui():
    """UI 点击：40ms 轻点。菜单里会连着点，必须轻。"""
    dur = 0.05

    def f(t, d):
        tone = math.sin(TAU * 1520.0 * t)
        return tone * env_ad(t, d, 0.001, 88.0)

    return finish(gen(dur, f), 0.38)


SFX = [
    ("shoot", sfx_shoot), ("hit", sfx_hit), ("kill", sfx_kill), ("hurt", sfx_hurt),
    ("pickup", sfx_pickup), ("levelup", sfx_levelup), ("card", sfx_card), ("skill", sfx_skill),
    ("boss_in", sfx_boss_in), ("boss_die", sfx_boss_die), ("zone", sfx_zone),
    ("dead", sfx_dead), ("clear", sfx_clear), ("ui", sfx_ui),
]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("合成音效 -> %s" % os.path.abspath(OUT_DIR))
    total = 0
    for name, fn in SFX:
        samples = fn()
        write_wav(name, samples)
        total += len(samples)
    print("合计 %.0f KB / %.2f 秒音频" % (total * 2 / 1024.0, total / RATE))


if __name__ == "__main__":
    main()
