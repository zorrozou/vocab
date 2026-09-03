# 项目进展手册（PROGRESS）

> 目的：让任何人（包括未来的自己）在 10 分钟内完整接手本项目。
> 最近更新：2026-09-04 · 状态：Web 版功能完整，多用户上线，例句质量全量打磨完成

---

## 1. 一句话现状

Web 单页学习应用已功能完整上线（定级/学习/复习/FSRS/个性化/语音全链路 + 多用户/游客模式）；词库 L1~L6 全部 10,991 词建成；例句质量全量打磨完成（交叉模型评审 54,861 句次，重写 16,603 句，隐藏低分语料 3,564 句，失败 0）；音频缓存 6.9 万条磁盘持久化。

**线上入口**：http://175.27.210.206/vocab/ （nginx → 127.0.0.1:8000）

## 2. 关键指标快照（2026-09-04）

| 指标 | 数值 |
|---|---|
| 词库 | 10,991 词（L1 903 / L2 1749 / L3 2000 / L4 1500 / L5 3000 / L6 1839） |
| 义项 | 21,212 条（核心/扩展/领域分级） |
| 例句 | 53,791 条（LLM 32,781 + 语料 20,387 + 模板 623；零例句词 0） |
| 质量打磨 | **评审 54,861 句次 / 重写 16,603 句 / 隐藏低分语料 3,564 句 / 失败 0**（2026-09-04 完成） |
| 中文翻译 | 53,086 句（98.7%） |
| 音频缓存 | **69,210 个 mp3（`data/tts_cache/`）** |
| 定级题库 | 30 题 4 选 1，15 词频带 × 2，按请求随机抽题 |
| 用户系统 | 用户名+密码（server/app/auth.py，users.db），支持游客模式与切号 |

## 3. 线上服务清单（175.27.210.206）

| 组件 | 位置 | 说明 |
|---|---|---|
| vocab-api | `~/vocab-api/`（systemd `vocab-api.service`，127.0.0.1:8000） | FastAPI；重启 `sudo systemctl restart vocab-api` |
| 词库 | `~/vocab-api/data/lexicon_v0.1.sqlite` | 7.4MB，WAL 模式 |
| 音频缓存 | **69,210 个 mp3（`data/tts_cache/`）** |
| 模型配置 | `/etc/vocab-api/vocab-api.env`（服务）· `pipeline.env`（批量） | 服务=hy3，批量=glm-5.2；`run-pipeline` 包装命令注入批量配置 |
| nginx | `/etc/nginx/sites-enabled/default` | `location /vocab/` 反代；主站证书 TrustAsia 已过期（2026-07-10），Let's Encrypt 因 DNSPod 境外 webblock 无法签——待处理 |
| 日志 | `journalctl -u vocab-api` · `~/vocab-api/*.log` | 量产日志在 vocab-api 根目录 |

## 4. 开发时间线

### 2026-08-05（设计日）
- 艾宾浩斯阶梯设计 → 评估后升级为 **FSRS-6**（理由：同保持率复习量 -20~30%，有官方 Swift/Python 实现）
- iOS 语音能力评估：SpeechAnalyzer（iOS 26 纯本地）可做转写；发音精评需云端（v2）
- 负载模拟：`review_load_simulation.py` 证明 30 词上限+复习优先成立；10 新词/天 → 稳态 ~92 词/天

### 2026-08-06（词库+服务端日）
- 词库管线：ECDICT（frq 词频 + cet4/6/ielts/toefl 标签）→ L1~L3 4652 词 + 义项拆分 + 词形归并
- **例句架构定稿**：静态保证层（编译期遗忘偏移 i-10/i-70/i-150/i-300 织入召回词）+ 动态个性化层
- 服务器 M0.5：加固（SSH 密钥/ufw/fail2ban）→ FastAPI → systemd → nginx `/vocab/`
- Web 学习页 v1：定级（网格贝叶斯）、学习卡、复习卡、阶梯调度
- 定级模拟验证：1~3 天收敛（`placement_simulation.py`）

### 2026-08-07（量产+打磨日）
- **三档例句体系**：基础/进阶/挑战（10/16/20 词）；多义词按义项配句；中文翻译全量回填
- **例句量产**：模板引擎(弃) → GLM+校验器 → **进程池 10 并发**（2 词/秒）；LLM 10,533 次调用产 29,129 句
- **音频**：edge-tts(AriaNeural) + 预热 17,274 条 + 跟随器实时补 12,529 条 = 34,028 缓存
- **FSRS-6 上线**：服务端 py-fsrs 端点，页面调度从阶梯迁移（旧卡自动换算）
- **复习 4 选 1**：两段式卡片，答错自动记「忘记」
- **自动播放**：Web Audio 定时调度连播（单词→停顿=下一句时长→三句）
- **定级升级**：30 题 4 选 1 实测 + 每次随机抽题
- **模型切换**：动态生成 hy3（腾讯 lkeap），批量 glm-5.2（双配置文件隔离）
- 个性化例句：完成学习自动触发（无手动按钮，无 cron）
- L4~L6 词包构建（词库 4652 → 10,991）

### 2026-08-26 ~ 08-28（例句策略定稿）
- **例句防牵强策略定稿**（用户确认）：多义词一词一卡只考核心义项；薄弱词织入概率化（40%、每词每天 ≤2 次、非每句织入）；个性化例句只服务薄弱词（新词不生成、已掌握词不再出现）
- 新学词增加当天测试轮 + 「不熟悉」自标按钮；当天记住的词次日复习、第三日起按概率出现
- 差句反馈按钮改名「↻换一句」（学习者视角，不做质量评判）
- 打磨批扩展覆盖 Tatoeba 语料句：低分语料句隐藏（flag='reported'），不改写真实语料

### 2026-09-02 ~ 09-03（模型与多用户）
- hy4-preview 评估后**回退 hy3**：强制推理关不掉，token 消耗约 10 倍、慢约 20 倍；`LLM_MAX_TOKENS` 环境变量化
- 个性化例句改**异步后台生成**：POST 24ms 返回 + 后台线程 4 工人并行
- **多用户上线**：server/app/auth.py（用户名+密码，users.db），页面支持欢迎/登录/注册/游客/切换，各用户进度隔离
- HTTPS 缓做：主站证书过期 + DNSPod 境外 webblock 导致 Let's Encrypt 签不了（用户拍板缓）

### 2026-09-04（例句质量全量打磨）
- **交叉模型评审**：quality_check 升级四维 rubric（语法/搭配/语义/场景各 ≥4），评审走 `LLM_JUDGE_*` 环境变量（当前 glm-5.2 评委，与生成模型 hy3 交叉）
- **全量打磨批**：三轮跑完全部 10,987 词——评审 54,861 句次 / LLM 句低分重写 16,603 句 / 语料句低分隐藏 3,564 句 / API 失败重试至 0
- **断点续跑**：`polish_state` 表记录已处理词，重跑自动跳过（polish_sentences.py）
- 抽查 12 条打磨后句子：语法正确、场景真实、翻译到位

## 5. 已知问题与遗留

| 优先级 | 事项 |
|---|---|
| 高 | L1 残留 149 个虚词例句待手工精修（the/of/and 类，从句档难自然成句） |
| 高 | 主站 zorrozou.online 证书过期；DNSPod 境外 webblock 导致 Let's Encrypt 无法验证（疑似未 ICP 备案） |
| 中 | 挑战句偶尔词汇越界被校验拦下（约 5% 词缺第三档，收尾批补齐中） |
| ~~中~~ | ~~召回词约束与绝对自然的张力~~ **已解决（2026-09-04 全量打磨批）** |
| 低 | `n't` 等碎片词条已在生产端拉黑，词库构建端待加过滤器 |
| 低 | GitHub token 曾明文出现在聊天中，建议用完即轮换 |

## 6. 下一步路线图

1. **M1 iOS App**（SwiftUI + SwiftData）：本仓库设计已全部就绪——PRD 见 docs/，调度用 swift-fsrs，转写用 SpeechAnalyzer，词库用本仓库 data/lexicon_v0.1.sqlite 起包
2. 词库内容：L1 虚词精修批、三档配齐率冲到 95%+、Tatoeba 自然句筛入（`pipeline/tatoeba_coverage.py` 已验证筛选率 L1 93%/L2 75%/L3 36%）
3. v1.5：FSRS 个性化优化器（≥400 条复习日志后本地拟合）、iCloud 同步
4. v2：云端发音精评（Azure/讯飞 GOP）、L4~L6 词包下载、Android

## 7. 常用运维命令

```bash
# 登录服务器
ssh -i ~/.ssh/vocab_server_ed25519 ubuntu@175.27.210.206

# 服务
sudo systemctl restart vocab-api && journalctl -u vocab-api -n 50

# 例句量产（进程池，断点续跑）
cd ~/vocab-api/pipeline && run-pipeline ../venv/bin/python -u gen_tiers_pool.py --start 1 --end 10991 --workers 10

# 音频补产
run-pipeline ../venv/bin/python -u tts_preheat.py          # 存量
run-pipeline ../venv/bin/python -u tts_follower.py         # 跟随新句

# 音频缓存包（本仓库 Release 的 tts_cache.tar.gz 即由此产生）
cd ~/vocab-api/data && tar -czf ~/tts_cache_$(date +%F).tar.gz tts_cache
```

## 8. 仓库资源说明

- `data/lexicon_v0.1.sqlite`：2026-08-07 快照（服务器上是活库，持续追加例句；以服务器为准，定期回拉）
- 音频缓存体积大不入 git 历史：**GitHub Release 资产 `tts_cache.tar.gz`**（1.24GB，69,210 文件，2026-09-03 打包，含全部产出），解压至 `data/` 即可完整复现
- 大型原始语料（ECDICT csv、Tatoeba tsv）不入库，获取方式见 `docs/词库建设方案.md`
