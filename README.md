# 词航 · 艾宾浩斯背单词

基于遗忘曲线与 FSRS 间隔重复的英语背单词应用。核心差异化：**例句三档难度体系 + 个人薄弱词织入例句 + 4 选 1 复习测试 + 全程神经网络语音**。

> 当前形态：Web 单页应用（浏览器直接可用）+ 云服务器后端。iOS 原生 App 在路线图 M1。

## 快速体验

**http://175.27.210.206/vocab/**

首次使用会进入 30 题智能定级（4 选 1，按词频带随机抽题），定级后开始每日学习闭环。

## 核心特性

| 特性 | 实现 |
|---|---|
| 调度 | **FSRS-6**（官方 py-fsrs，保持率 90%），服务端计算 |
| 智能定级 | 30 题 4 选 1 实测 + 网格贝叶斯估计，每次随机抽题 |
| 例句 | **三档难度**：基础 ≤10 词（跟读）/ 进阶 ≤16 词（含从句）/ 挑战 ≤20 词（复合结构），多义词按义项分配 |
| 个性化例句 | 每日学习完成后自动：明日新词 × 近 7 天薄弱词 → 大模型定制 |
| 复习 | **4 选 1 词义测试**（干扰项同词性邻近词频），答错自动记「忘记」 |
| 语音 | 神经网络 TTS（edge-tts / AriaNeural），自动连播「单词→停顿→三句」，全程缓存零延迟 |
| 词库 | L1~L6 六级 10,991 词（COCA 词频 + 四六级/雅思考纲标签） |

## 架构

```
浏览器（单页应用，localStorage 学习状态）
   │  /vocab/ → nginx 反代
   ▼
vocab-api (FastAPI, systemd)
   ├─ 词库/例句/测验/定级端点（SQLite 10,991 词 / 29,000+ 例句）
   ├─ FSRS 调度端点（py-fsrs）
   ├─ 个性化例句（夜间自动触发）
   └─ TTS 音频端点（edge-tts + 磁盘缓存 34,000+ 文件）
        │
        ├─ 大模型：动态生成走 hy3（腾讯 lkeap）/ 批量脚本走 glm-5.2（智谱）
        └─ 生产管线（pipeline/）：进程池批量生成例句、翻译、音频
```

## 目录

```
docs/        PRD、词库建设方案、负载/定级模拟图表
server/      FastAPI 服务端（app/main.py）与定时脚本
web/         单页学习应用（index.html，无框架）
pipeline/    词库构建、例句/翻译/音频批量生产（进程池）
simulation/  复习负载与定级收敛的模拟验证脚本
config/      部署配置样例（env 模板、systemd、nginx）
data/        lexicon_v0.1.sqlite（词库快照）
```

## 部署（摘要）

1. `config/vocab-api.env.example` 复制为 `/etc/vocab-api/vocab-api.env`，填入 `LLM_API_KEY / LLM_BASE_URL / LLM_MODEL`；批量脚本配置放 `pipeline.env`
2. `python3 -m venv venv && pip install fastapi uvicorn edge-tts fsrs`
3. `systemctl enable --now vocab-api`（unit 见 config/）
4. nginx 反代 `location /vocab/ → 127.0.0.1:8000/`（见 config/nginx-vocab.conf.snippet）
5. 音频缓存：Release 资产 `tts_cache.tar.gz` 解压到 `data/`（见 PROGRESS.md）

详细进展与运维手册见 **[PROGRESS.md](PROGRESS.md)**，产品需求见 **[docs/PRD-艾宾浩斯背单词App.md](docs/PRD-艾宾浩斯背单词App.md)**。
