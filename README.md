# Meeting Minutes | 中英会议纪要

在 Codex 中，把普通话、英语或中英混合的会议录音整理成带时间线索的纪要，并按请求保存到 Notion。已有转录稿、字幕或会议笔记时，可直接从文字开始。

## 使用

用 Codex 打开本仓库，输入 `$meeting-minutes` 调用技能。要在其他项目也使用，可以把 `.agents/skills/meeting-minutes` 整个目录复制到 `~/.agents/skills/`，再开启新会话。安装位置见 [Codex 技能文档](https://developers.openai.com/codex/skills)。

> $meeting-minutes 用我附上的会议录音生成简体中文纪要，保留英文术语，给决定和行动项标注时间码。完成后保存到我附上的 Notion 页面。

有 Notion 连接时，在首次请求中附上目标页面或数据库链接。也可说“保存到我的默认 Notion 会议纪要位置”。后续修改同一份纪要时，保留它旁边的同步记录，便于更新原页面。项目使用 Codex 的 Notion 连接，连接配置保存在应用中。

## 本机转写

macOS 可用 Homebrew 安装工具。使用已转录的文字或字幕时可跳过此节。

```bash
brew install ffmpeg whisper.cpp
mkdir -p models
curl --fail --location --output models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

模型文件约 1.5 GiB，来源和校验值见 [whisper.cpp 模型说明](https://github.com/ggml-org/whisper.cpp/tree/master/models)。从仓库根目录调用脚本可单独取得带时间码的 SRT 转录稿。

```bash
python3 .agents/skills/meeting-minutes/scripts/transcribe.py /path/to/meeting.m4a \
  --model models/ggml-large-v3-turbo.bin --language zh \
  --output meetings/demo/transcript.srt
```

普通话为主选 `zh`，英文为主选 `en`。中英混合可先用 `auto`，并通过 `--glossary` 提供 UTF-8 术语表。自动检测为录音选择主要语言。遇到频繁切换、重叠发言、人名或缩写时，回听关键片段，必要时按语言分段重转。单轨流程不自动识别发言人。

## 分享仓库

录音在本机转写。Codex 读取转录稿生成纪要，选择同步时，纪要正文会发送到所选 Notion 位置。把录音、转录稿、真实纪要和同步记录统一存放在被 Git 忽略的 `meetings/`，模型放在 `models/`。发布前检查 Git 暂存区，只提交技能文件和说明。

创建空的 GitHub 仓库后，可以在这个项目目录运行下列命令。把 `<owner>` 换成 GitHub 用户名或组织名。

```bash
git remote add origin https://github.com/<owner>/meeting-minutes.git
git push -u origin main
```

## macOS 在线会议录音原型

在 macOS 15 或更新版本上，从仓库根目录编译并运行：

```bash
sh macos/build.sh
build/watch-meetings --calendar
```

开启 `--calendar` 后，允许读取 Apple Calendar。先在 macOS「互联网账户」中加入 Google 和公司 Microsoft Exchange 账户，并开启日历同步。助手在后台运行时，会在带已支持会议链接的日程开始前五分钟提示。公司账户能否同步取决于组织策略，部分邀请的会议链接也可能未同步到本机。

Teams 桌面版同时使用输入和输出设备时，助手会弹出录音选择。这个信号也可能来自设备测试或通话预览，点击前请确认已入会。首次录音需要授予麦克风和屏幕与系统音频录制权限。确认后分别写入 `remote.caf` 和 `microphone.caf`，不保存画面。会议结束时点击停止并保存。使用 Teams 网页版或检测失败时，可手动启动：

```bash
mkdir -p meetings
build/record-meeting meetings/teams-example
```

两个音轨和时间信息保存在同一目录。可以把两个音轨和 `capture.json` 一起交给 `$meeting-minutes`。若双方存在重叠发言，优先分别识别并按时间合并。多位远端发言人仍共用一条音轨。

录音与提醒原型需要用一次真实 Teams 通话和两种账户的邀请验收。实时双语字幕和模型评测见 [新版流程与选型](docs/workflow.md)。

## 停录后自动生成并同步

本机转写环境就绪后，可以在启动录音助手的终端中配置以下环境变量。凭据请保存在本机，避免写入仓库或聊天。

- `OPENAI_API_KEY` 使用有 API 用量额度的项目密钥。默认模型为 `gpt-6.1-sol`，可用 `MEETING_MINUTES_MODEL` 覆盖。
- `NOTION_TOKEN` 使用 Notion 工作区的内部连接凭据，开启 Insert content，并从目标普通页面的 **Connections** 菜单将连接添加到该页面。
- `NOTION_PARENT_PAGE_ID` 使用该普通页面的 UUID。每份纪要会创建为一个子页面。

[OpenAI API 配置](https://developers.openai.com/api/docs/quickstart) · [Notion 内部连接说明](https://developers.notion.com/guides/connections-and-tokens/internal-connections)

先单独跑一次已完成的录音目录，再开启自动模式：

```bash
sh macos/process-meeting.sh meetings/your-capture-directory
sh macos/build.sh
build/watch-meetings --calendar --auto-publish
```

自动模式在停录成功后启动处理，完成时显示 Notion 链接。音频和转录留在本地，OpenAI 收到带时间码的转录文本，Notion 收到最终纪要。若同步失败，重跑同一个录音目录可复用已保存的转录和纪要。若程序提示上一次写入结果不明，先在目标页面查找该纪要。确认未创建后再移除录音目录里的 `.notion-write-pending` 并重试。
