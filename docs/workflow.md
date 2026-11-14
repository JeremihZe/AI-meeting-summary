# 在线会议流程与模型评测

## 从日程到纪要

1. 日历读取。当前原型通过 EventKit 查询已同步到 Apple Calendar 的日程。它只读取日程。通过 macOS 互联网账户同步 Google Calendar 和 Microsoft Exchange。先检查这两种账户各有一条含入会链接的测试日程。若 Exchange 被组织策略限制，评估 Microsoft Graph 的委托日历权限和 `calendarView`。Google 也可用 Calendar API 只读授权直连。
2. 入会提示。Teams 桌面版的本机音频活动触发确认窗口。日历只提示即将开始的会议。测试中要区分真正入会、设备预览、静音入会和无日程的临时通话。
3. 双路录音。通过 ScreenCaptureKit 分别保存会议应用音频和本机默认麦克风。用耳机复核两路串音，用测试句验证双路音量、起点和长会漂移。原型支持手动停录。需要实测蓝牙耳机、Teams 自定义麦克风和 Teams 分进程场景。
4. 转写、纪要与同步。分别识别两路并合并时间轴。纪要中的决定、待办、负责人和期限保留证据位置。生成后用已连接的 Notion 同步并保存链接。目前由用户在 Codex 中调用技能处理刚录完的文件。
5. 可选实时字幕。取同样的两路输入，显示原语字幕。仅翻译已稳定的片段以减少跳字。会后转录允许用更准确的模型重新识别。原型还未提供实时字幕面板。

资料：[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) · [EventKit](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui) · [Microsoft Graph 日历视图](https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview) · [Google Calendar Events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list)。

## 模型候选

| 环节 | 先测 | 对比与取舍 |
| --- | --- | --- |
| 会后识别 | FunASR 的 SenseVoiceSmall + FSMN-VAD | 与 Whisper large-v3-turbo 和 Fun-ASR-Nano 比较。记录本机耗时，检查中英切换、时间戳和英文术语。Whisper 是第一版基线。 |
| 实时原语字幕 | FunASR 的流式 Paraformer | 用普通话主导、纯英文、句内中英切换分别压测。若切换片段丢词，再比较 Qwen3-ASR 的流式方案。 |
| 中英互译 | 本地 Qwen 候选，固定会议术语表 | 测英文到中文和中文到英文。对照专名、数字和缩写，单独记录稳定字幕到译文的延迟。 |
| 结构化纪要 | 已连接的 Codex 模型与本地 Qwen3-8B | 同一转录稿和结构下比较真实决定召回、提案误判、待办归属与证据时间码。若要求全程本地，使用本地模型生成纪要后仅上传最终纪要。 |

资料：[FunASR 官方选型指南](https://github.com/modelscope/FunASR/blob/main/docs/model_selection.md) · [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) · [Qwen3](https://github.com/QwenLM/Qwen3) · [Whisper.cpp 模型说明](https://github.com/ggml-org/whisper.cpp/tree/master/models)。

建议用同意参与测试的双人通话，分别录一段普通话主导、一段纯英文和一段句内混合。标出原文、发言时间、术语、人名、数字和最终决定。转写按中文字符错误率、英文词错误率、关键信息错误以及耗时比较。字幕额外测首字和稳定片段延迟。纪要按决定是否有证据、待办字段是否准确以及遗漏数逐项检查。模型依据这组结果和本地处理要求一起决定。

## 第一轮会后转写

先用 SenseVoiceSmall 和 FSMN-VAD 在本机 CPU 识别。测试目录需要录音程序生成的 `capture.json` 和两路 CAF 音频。首次运行会下载模型权重。使用独立 Python 环境：

```bash
python3 -m venv build/funasr-venv
build/funasr-venv/bin/python -m pip install "funasr==1.4.25" torch torchaudio modelscope
build/funasr-venv/bin/python .agents/skills/meeting-minutes/scripts/transcribe_capture.py meetings/<capture-directory>
```

输出的 `transcript.sensevoice.json` 保留音轨和相对会议起点的毫秒时间。两路有重叠时仍保留各自条目。分段时间来自语音活动检测。原始转录留在本地，人工校对另存一份。若录音标明时间戳有间断，自动转录入口会停止并提示人工复核。实测前不要将系统生成的时间码当作逐词定位。

后续把处理任务接到录音成功结束的位置。先写本地转录，成功后把带时间码的文本送给选定的云端模型生成结构化纪要，再用 Notion API 归档。后台程序需要独立配置云端和 Notion 凭据。上传前保留任务状态，Notion 成功时保存页面 ID，遇到写入超时时先核实结果再重试。录音和校对用的转录留在本地，Notion 保存最终纪要。
