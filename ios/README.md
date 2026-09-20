# 词航 iOS App（M1）

Web 版（http://175.27.210.206/vocab/）的原生 iOS 客户端。调度、例句、音频、账号与进度同步**全部复用现有服务端**，App 是原生体验壳 + 跟读评分（Web 端做不了的核心能力）。

## 功能（与 Web 版 1:1 对齐）

- 智能定级：30 道 4 选 1，网格贝叶斯估计词汇边界，答错词自动入学习计划
- 每日队列：到期复习 → 提前巩固概率池（P=(1−R)×0.5，≤5 个）→ 新词（默认 10 个/天）
- 复习两段卡：先 4 选 1 实测，答错自动记「忘记」，答对再选 困难/记得/熟练
- 新词卡：三档例句（基础/进阶/挑战）+ 个性化例句 + 巩固句（40% 概率织入近期薄弱词，每天 ≤3 次）
- 自动连播：单词 → 停顿（=下一句时长，留跟读时间）→ 例句们，全部走服务端 edge-tts 缓存
- **🎤 跟读评分**：SFSpeechRecognizer 设备端识别（不上传），完整度 + 置信度双子分
- 当日验收测试：新词学完 4 选 1 验收，答错进薄弱词当晚定制例句
- 完成后自动个性化：薄弱词 → 后台生成复习例句（轮询取回 + 音频预热）
- FSRS-6 调度：服务端 py-fsrs 计算（断网自动退本地阶梯兜底，与 Web 一致）
- 多用户：注册/登录/游客/切换，token 存 Keychain，进度本地 JSON + 服务器防抖 2s 同步（**与 Web 端 state 完全同构，两端可随时互换继续学**）
- 统计：记忆保持率分桶、未来 14 天负载、顽固词；设置：新词数/上限/嗓音

## 跑起来（需要 Xcode）

```bash
# 1) 安装 Xcode（App Store，首次约 10GB+）
# 2) 安装 XcodeGen 并生成工程
brew install xcodegen
cd ios && xcodegen
# 3) 打开工程
open VocabApp.xcodeproj
# 4) Xcode 里 Signing & Capabilities 选你自己的 Team（免费个人证书即可）
# 5) 选 iPhone 模拟器或真机，⌘R 运行
```

真机运行免费证书即可，无需付费开发者账号。首次运行会请求**麦克风**和**语音识别**权限（跟读用，纯本机识别）。

## 架构

```
VocabApp/
├── VocabApp.swift        # @main + 路由（RootView）
├── Config.swift          # API 地址（http://175.27.210.206/vocab）
├── Models.swift          # 学习状态 LearningState（与 Web state 字段级同构）+ API DTO + 日期工具
├── Keychain.swift        # token 安全存储
├── APIClient.swift       # 全部服务端端点（actor）
├── AudioService.swift    # TTS 下载 + 自动连播链（AVAudioPlayer 定时调度）
├── SpeechService.swift   # 跟读识别评分（SFSpeechRecognizer 设备端）
├── StudyEngine.swift     # 纯逻辑：FSRS 请求构造/阶梯兜底/掌握判定/定级贝叶斯/薄弱词/保持率
├── AppState.swift        # 编排层：状态持久化与同步、队列构建、学/复习写卡、个性化、织入、换句
└── Views/
    ├── AuthViews.swift   # 欢迎/登录/注册/用户菜单
    ├── HomeView.swift    # 状态条 + 今日任务
    ├── PlacementView.swift  # 定级 30 题
    ├── SessionViews.swift   # 学习卡/复习卡/答案卡/验收测试/完成页
    ├── StatsView.swift   # 统计
    ├── SettingsView.swift   # 设置
    └── Components.swift  # 主题/按钮/例句行/4选1组件
```

关键设计：

- **state 同构**：`LearningState` 字段与 Web 端 `vocab_v1` 一一对应（含运行期扩展字段 quizDay/weaveDay/weaveCount/wrongStreak/personalizedDay/personalizedWeak），UTC 日期口径一致，跨端同步无损
- **调度单一事实源**：FSRS 一律走服务端 `/api/v1/fsrs/review`，App 不内置第二套算法（离线才走阶梯兜底）
- **日期字符串原样保留**：due 等时间不做 Date 往返，避免格式漂移
- **HTTP 明文**：Info.plist 已对 175.27.210.206 加 ATS 例外（HTTPS 上线后可移除）

## 已知边界 / TODO

- M1.5：跟读升级 SpeechAnalyzer（iOS 26+ 无时长限制 + 词级时间戳 → 流利度子分）
- M2：离线模式（`/api/v1/lexicon/download` 整包起包 + 本地调度）、本地通知提醒
- 当前无单元测试（调度逻辑与 Web 对拍验证过；Xcode 就位后补 StudyEngine 单测）
- 首次 Xcode 构建如遇小问题（签名/版本警告类），按提示处理或找我修
