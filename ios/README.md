# 词航 iOS App（M1）

Web 版（https://175.27.210.206/vocab/）的原生 iOS 客户端。调度、例句、音频、账号与进度同步**全部复用现有服务端**，App 是原生体验壳 + 跟读评分（Web 端做不了的核心能力）。

## 功能（与 Web 版 1:1 对齐）

- 智能定级：30 道 4 选 1，网格贝叶斯估计词汇边界，答错词自动入学习计划
- 每日队列：到期复习 → 提前巩固概率池（P=(1−R)×0.5，≤5 个）→ 新词（默认 10 个/天）
- 复习两段卡：先 4 选 1 实测，答错自动记「忘记」，答对再选 困难/记得/熟练
- 新词卡：三档例句（基础/进阶/挑战）+ 个性化例句 + 巩固句（40% 概率织入近期薄弱词，每天 ≤3 次）
- 自动连播：单词 → 停顿（=下一句时长，留跟读时间）→ 例句们，全部走服务端 edge-tts 缓存
- **🎤 跟读评分**：SFSpeechRecognizer 设备端识别（不上传），完整度 + 置信度双子分
- 当日验收测试：新词学完 4 选 1 验收，答错进薄弱词当晚定制例句
- 完成后自动个性化：薄弱词 → 持久化后台任务；应用回到主页或前台时恢复待处理任务，部分失败可重新提交
- FSRS-6 调度：服务端 py-fsrs 计算；断网评分保存在本地待处理队列，暂用阶梯估计到期时间，连接恢复后按原时间重放，与 Web 一致。不同设备对同一张卡产生无法安全合并的分叉时，同步会提示失败并保留本地进度。
- 多用户：注册/登录/游客/切换，token 存 Keychain，进度本地 JSON + 服务器防抖 2s 同步（**与 Web 端 state 完全同构，两端可随时互换继续学**）
- 统计：记忆保持率分桶、未来 14 天负载、顽固词；设置：新词数/上限/嗓音
- 备份：设置页可导出或选择备份恢复；账号菜单可重新加载服务器进度并导出服务器恢复前备份。恢复前会保留本机旧档，旧设备不会自动覆盖恢复后的服务器状态。

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
├── Config.swift          # API 地址（https://175.27.210.206/vocab）
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

- **state 同构**：`LearningState` 字段与 Web 端 `vocab_v1` 对应（含运行期扩展字段 quizDay/weaveDay/weaveCount/wrongStreak/personalizedDay/personalizedWeak）；学习日按设备本机日历，调度时间保留时区。跨时区使用时两台设备的「今天」可能不同。
- **调度单一事实源**：FSRS 一律走服务端 `/api/v1/fsrs/review`；离线只用阶梯给出临时到期时间，待处理评分重放成功后以 FSRS 结果替换。
- **日期字符串原样保留**：due 等时间不做 Date 往返，避免格式漂移
- **服务地址**：Release 默认使用 `https://175.27.210.206/vocab`，只接受 HTTPS；可通过构建设置 `VOCAB_API_BASE_URL` 指定其他 HTTPS 地址。IP 证书需保持自动续期。

## 已知边界 / TODO

- M1.5：跟读升级 SpeechAnalyzer（iOS 26+ 无时长限制 + 词级时间戳 → 流利度子分）
- M2：完整离线模式（`/api/v1/lexicon/download` 整包起包 + 本地调度）；每日本地通知提醒已实现。
- 逻辑回归包含学习日期、时区及调度等检查；更多场景通过隔离模拟器验证。
- 首次 Xcode 构建如遇小问题（签名/版本警告类），按提示处理或找我修

### 隔离的模拟器界面回归

在安装了 Xcode、iOS 模拟器运行时和服务端依赖的环境中，先启动 `python tests/ui_stub_server.py`。该服务复制词库到临时目录并使用替身生成服务，不读写项目用户库。确认目标模拟器已启动后，在另一个终端执行 `tests/run_ios_ui_regression.sh <模拟器 UDID> guest` 或 `tests/run_ios_ui_regression.sh <模拟器 UDID> account` 或 `tests/run_ios_ui_regression.sh <模拟器 UDID> offline` 或 `tests/run_ios_ui_regression.sh <模拟器 UDID> recovery`。离线用例模拟评分和状态上传服务不可用，并在恢复后核对重放结果；它不模拟设备网络切换。脚本使用临时 Xcode 项目和独立应用标识，测试仅连接本机隔离服务；运行结束会卸载该测试应用。

学习日期和本地时区的独立回归（在仓库根目录执行）：

```sh
xcrun swiftc ios/VocabApp/Models.swift tests/ios_local_noon_regression.swift -o /tmp/vocab-local-noon-test
TZ=Asia/Shanghai /tmp/vocab-local-noon-test 2026-10-29 2026-10-29T04:00:00Z
TZ=America/New_York /tmp/vocab-local-noon-test 2026-03-08 2026-03-08T16:00:00Z
TZ=America/New_York /tmp/vocab-local-noon-test 2026-11-01 2026-11-01T17:00:00Z
TZ=Pacific/Kiritimati /tmp/vocab-local-noon-test 2026-10-29 2026-10-28T22:00:00Z
xcrun swiftc ios/VocabApp/NotificationService.swift tests/ios_reminder_regression.swift -o /tmp/vocab-reminder-test
/tmp/vocab-reminder-test
xcrun swiftc ios/VocabApp/Models.swift tests/ios_quiz_feedback_regression.swift -o /tmp/vocab-quiz-feedback-test
/tmp/vocab-quiz-feedback-test
```

应用图标的矢量源为 `app-icon.svg`。修改后，在具有 Playwright 和 Chrome 的环境中从仓库根目录运行 `node ios/render_app_icon.cjs`，更新资源目录中的 1024 像素 PNG。发布构建应包含 `Assets.car` 和实际 AppIcon，而非系统占位图标。
