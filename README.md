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
