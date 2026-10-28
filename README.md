# 词航 · 艾宾浩斯背单词

基于遗忘曲线与 FSRS 间隔重复的英语背单词应用。核心差异化：**例句三档难度体系 + 个人薄弱词织入例句 + 4 选 1 复习测试 + 全程神经网络语音**。

> 当前形态：Web 单页应用、iOS 客户端和 FastAPI 服务端。同步与离线冲突处理仍在完善中。

## 快速体验

请按“本地启动”运行。当前 iOS 部署按要求使用 IP 的明文 HTTP，账号密码、令牌和学习数据在传输中不加密；如需加密，应配置有效证书并使用 HTTPS。

首次使用会进入 30 题智能定级（4 选 1，按词频带随机抽题），定级后开始每日学习闭环。

## 核心特性

| 特性 | 实现 |
|---|---|
| 调度 | **FSRS-6**（官方 py-fsrs，保持率 90%），服务端计算 |
| 智能定级 | 30 题 4 选 1 实测 + 网格贝叶斯估计，每次随机抽题 |
| 例句 | **三档难度**：基础 ≤10 词（跟读）/ 进阶 ≤16 词（含从句）/ 挑战 ≤20 词（复合结构），多义词按义项分配 |
| 个性化例句 | 每日学习完成后自动：明日新词 × 近 7 天薄弱词 → 大模型定制 |
| 复习 | **4 选 1 词义测试**（优先同词性和邻近词频，稀有词性会标注兜底选项的词性），答错自动记「忘记」 |
| 语音 | 神经网络 TTS（edge-tts / AriaNeural），自动连播「单词→停顿→三句」，全程缓存零延迟 |
| 词库 | L1~L6 六级；仓库快照为 10,987 词（COCA 词频 + 四六级/雅思考纲标签） |

## 架构

```
浏览器（单页应用，localStorage 学习状态）
   │  /vocab/ → nginx 反代
   ▼
vocab-api (FastAPI, systemd)
   ├─ 词库/例句/测验/定级端点（SQLite 快照）
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

## 本地启动

从仓库根目录执行（不覆盖已有词库和静态文件）：

```sh
python3 -m venv .venv
.venv/bin/pip install -r server/requirements.txt
mkdir -p server/data server/static
test -e server/data/lexicon_v0.1.sqlite || cp data/lexicon_v0.1.sqlite server/data/
test -e server/static/index.html || ln -s ../../web/index.html server/static/index.html
cd server
../.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

访问 `http://127.0.0.1:8000/`。新生成例句和部分音频需要配置外部服务；未配置 LLM 时静态词库仍可使用。`server/data/` 包含用户、学习和个性化数据，不要提交到 Git。设置页可导出和导入本机学习进度；导入前会预览并确认，登录状态下会在事务中备份服务器旧档并检查服务器是否发生变化。文件包含个人学习记录，应自行妥善保管。游客个性化请求使用服务器签发的本机凭证；备份不包含凭证，更换设备或清除应用数据后旧云端任务无法取回，可重新生成。升级前的游客设备号无法证明归属，旧游客云端任务不会自动迁移，本机已保存的学习记录和例句仍保留。

恢复后，旧设备的同步会收到冲突提示，以免覆盖恢复结果。先在旧设备导出本地进度；如确认采用服务器版本，可在账号菜单选择“重新加载服务器进度”，操作会先保存该设备本地旧档。账号菜单也可导出恢复前的服务器备份。备份恢复流程本身不会自动合并被替换的进度。

### 词库分页兼容

`GET /api/v1/lexicon/at` 保留 `from` 和 `words`，并返回 `next_pos`（下一个尚未扫描的位置）和 `exhausted`（是否已扫描到词库末尾）。单页最多扫描 40 个位置，`words` 可能为空但 `exhausted` 仍为 `false`；调用方应继续请求 `next_pos`。新版客户端兼容旧服务端的非空响应，但旧服务端的空响应无法证明词库已结束，会提示重试。部署时应先升级服务端，再升级客户端。

### 离线评分与多设备冲突

新客户端会保存每张卡的重放起点、评分事件和调度参数指纹。两个设备从同一起点产生的评分会按事件 ID 去重、按时间排序，再由客户端调用服务端重算；每次评分记录其实际参数版本，跨参数更新也可按原版本重放。状态在重算完成前仍标记为待同步。旧客户端没有完整历史、起点不一致或参数版本无法验证时，服务器会拒绝不安全的合并，客户端保留本地数据并提示导出。

评分历史不会自动压缩；长时间使用可能触及 8 MiB 状态上限。登录用户可在设置中主动整理已同步的历史：服务器保留整理前备份并建立新基线；其他设备须提前同步并导出离线进度，旧版本需要重新加载。存在待重放或无法证明完整的评分历史时会拒绝整理。接近上限时应及时整理；如果本机已超过上限且无法上传，仍需先导出并人工处理，检查点不能直接合并未上传数据。服务端将用户使用过的参数快照保存在 `personal.db`；两端在线导出时会将可用快照打包进学习状态，服务器恢复时校验指纹。离线导出、旧备份或服务器缺失快照时可能不完整；升级 `fsrs` 算法库后旧实现也不一定能重放。生产服务器备份仍须同时保护 `users.db`、`personal.db` 和优化参数文件。遇到冲突请先导出进度，不要删除待处理事件。历史排序依赖设备时间，跨设备时钟错误仍需要检查。

可选的 FSRS 参数优化需要额外安装 `python -m pip install 'fsrs[optimizer]==6.3.2'`，再运行 `python pipeline/optimize_fsrs_user.py 用户数字ID`。脚本默认读取并写入 `server/data/`；部署目录不同时使用 `--data-dir /实际服务数据目录`。只使用已应用且有精确时间的评分事件，至少需要 400 条；只有日期的旧日志、待同步事件和整理前已被压缩的事件不能可靠用于训练。不足时保留现有参数。设备时钟错误可能影响训练，优化结果仍需在真实留存数据上验证。

## 部署（摘要）

1. `config/vocab-api.env.example` 复制为 `/etc/vocab-api/vocab-api.env`，填入 `LLM_API_KEY / LLM_BASE_URL / LLM_MODEL`；批量脚本配置放 `pipeline.env`
2. 安装 `server/requirements.txt`，将词库和静态页面放入服务端 `data/` 与 `static/`；目录路径与 systemd unit 保持一致
3. `systemctl enable --now vocab-api`（unit 见 config/）
4. nginx 反代 `location /vocab/ → 127.0.0.1:8000/`（见 config/nginx-vocab.conf.snippet）；该示例状态上限为 8 MiB，更新线上配置后需测试并重载 nginx。正式部署还需配置有效 HTTPS 证书及客户端 HTTPS 地址。
5. 音频缓存：Release 资产 `tts_cache.tar.gz` 解压到 `data/`（见 PROGRESS.md）

服务端对登录、注册、例句生成、反馈和音频请求设置了进程内限流。systemd 示例只信任来自本机代理的转发地址；多进程或多机部署还需在可信网关配置共享限流，且不能直接信任客户端自填的转发头。

HTTPS 参考 `config/nginx-vocab-https.conf.example`，必须先替换域名、配置有效证书并验证后再重载。按部署要求，iOS Release 默认使用 `http://175.27.210.206/vocab`，仅对这一确切地址允许 HTTP；也可通过构建设置 `VOCAB_API_BASE_URL` 指定 HTTPS 地址。HTTP 传输不会加密账号密码、令牌和学习数据。

详细进展与运维手册见 **[PROGRESS.md](PROGRESS.md)**，产品需求见 **[docs/PRD-艾宾浩斯背单词App.md](docs/PRD-艾宾浩斯背单词App.md)**。

### 密码迁移

新账号使用 Argon2id，旧 PBKDF2 密码在成功登录时升级。上线前需安装更新后的依赖并停止旧版服务；旧程序不能验证升级后的密码，回滚时需恢复升级前的数据库备份。认证计算按进程限制并发，生产网关仍需统一限流。

### 离线备份和回滚准备

升级前先停止 API、定时任务及所有其他数据写入者，并确认它们已退出。`--writers-stopped` 是操作人员的声明，工具不能检测所有写入者；若仍有写入，多个数据库与参数文件之间的快照不保证一致。将备份放在仓库和服务器数据目录之外的受限位置：

```bash
python server/backup_state.py create --data /path/to/server/data --output /safe/new-backup-dir --writers-stopped
python server/backup_state.py verify --backup /safe/new-backup-dir
python server/backup_state.py restore --backup /safe/new-backup-dir --output /safe/new-restore-staging-dir
# 如果不通过本工具恢复，而是手工替换了数据库：停止所有写入后执行
python server/backup_state.py reset-sync-generation --data /path/to/server/data --writers-stopped
```

工具使用 SQLite 备份接口包含已提交的 WAL，保存 `users.db`、`personal.db`、存在时的词库数据库和 `fsrs_optimal*.json`，并检查数据库完整性及文件 SHA-256。输出目录必须不存在；恢复只写入新的暂存目录，不能直接覆盖运行中的数据库。对于已有同步代次的数据库，暂存副本先按清单核对，再轮换同步代次并清除临时快照及增量日志；因此暂存数据库不再与原备份逐字节相同，但用户学习状态保留。手工替换数据库若跳过代次重置，增量游标可能错误地复用，不能安全接入增量同步。备份包含用户数据且未加密，校验和用于发现损坏，不证明备份来源可信；请另行加密、限制权限并按需要安全保存。备份不包含配置密钥、应用代码或可重建的音频缓存，需按部署情况分别保护。

正式回滚前应再次停止所有写入，备份当前数据，核对暂存文件与目标程序版本，并按部署流程一起切换数据库、参数文件和应用版本；切换后验证登录、状态和例句。不要将整个暂存目录直接覆盖原目录，以免丢失未由工具备份的其他文件。仓库中的隔离演练不能代替生产环境的备份恢复演练。
