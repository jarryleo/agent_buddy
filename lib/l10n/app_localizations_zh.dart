// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Agent Buddy';

  @override
  String get commonAdd => '新增';

  @override
  String get commonSave => '保存';

  @override
  String get commonCancel => '取消';

  @override
  String get commonDelete => '删除';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonInUse => '使用中';

  @override
  String get commonError => '出错';

  @override
  String get commonConfirm => '确认';

  @override
  String get homeSettingsTooltip => '设置';

  @override
  String get homeClearChatTooltip => '清空对话';

  @override
  String get homeClearChatTitle => '清空对话';

  @override
  String get homeClearChatMessage => '确认清空所有消息?此操作不可撤销。';

  @override
  String get homeClearChatConfirm => '清空';

  @override
  String get homeEmptyTitle => 'Agent Buddy';

  @override
  String get homeEmptySubtitle => '点击左上角设置按钮,添加模型提供商与角色后开始对话。';

  @override
  String get homeSessionsTooltip => '会话';

  @override
  String get sessionManagerTitle => '会话管理';

  @override
  String get sessionManagerNew => '新建会话';

  @override
  String get sessionManagerEmpty => '暂无历史会话';

  @override
  String get sessionManagerSelectAll => '全选';

  @override
  String get sessionManagerDeselectAll => '取消全选';

  @override
  String get sessionManagerDelete => '删除';

  @override
  String get sessionManagerDeleteConfirmTitle => '确认删除会话?';

  @override
  String sessionManagerDeleteBatchConfirmTitle(int count) {
    return '确认删除 $count 个会话?';
  }

  @override
  String get sessionManagerDeleteMessage => '选中的会话将被删除,且无法恢复。';

  @override
  String get homeNoModel => '未配置模型';

  @override
  String get homeNoModelSelected => '未选模型';

  @override
  String homeProviderModel(String provider, String model) {
    return '$provider · $model';
  }

  @override
  String get homeCopied => '已复制';

  @override
  String get homeLocalModelLoading => '正在加载模型…';

  @override
  String get homeLocalModelReady => '模型已加载';

  @override
  String get homeLocalModelRelease => '释放模型';

  @override
  String get homeLocalModelReleaseTooltip => '从内存中释放本地模型';

  @override
  String get homeLocalModelReleased => '模型已释放';

  @override
  String homeLocalModelLoadFailed(String error) {
    return '模型加载失败: $error';
  }

  @override
  String get homeLocalModelRetry => '重试';

  @override
  String get homeLocalModelDismiss => '忽略';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsTabGeneral => '常规';

  @override
  String get settingsTabProvider => '模型';

  @override
  String get settingsTabRole => '角色';

  @override
  String get settingsTabTools => '工具';

  @override
  String get settingsTabSkill => '技能';

  @override
  String get settingsTabMcp => 'MCP';

  @override
  String get settingsTabMemory => '记忆';

  @override
  String get providerListEmpty => '还没有添加任何模型提供商\n点击右下角\"新增\"开始';

  @override
  String get providerAddTitle => '新增提供商';

  @override
  String get providerEditTitle => '编辑提供商';

  @override
  String get providerProtocol => '协议';

  @override
  String get providerProtocolOpenAI => 'OpenAI';

  @override
  String get providerProtocolAnthropic => 'Anthropic';

  @override
  String get providerName => '名称';

  @override
  String get providerNameHint => '例如: OpenAI 官方';

  @override
  String get providerNameRequired => '请输入名称';

  @override
  String get providerBaseUrl => 'Base URL';

  @override
  String get providerBaseUrlHint => 'https://api.openai.com';

  @override
  String get providerBaseUrlRequired => '请输入 Base URL';

  @override
  String get providerApiKey => 'API Key';

  @override
  String get providerApiKeyRequired => '请输入 API Key';

  @override
  String get providerChatPath => 'Chat Path';

  @override
  String get providerChatPathHelper => '已根据协议自动补全,通常无需修改';

  @override
  String get providerChatPathRequired => '请输入 Chat Path';

  @override
  String get providerTestConnection => '测试连接';

  @override
  String get providerFetchModels => '获取模型';

  @override
  String get providerSelectModel => '选择默认模型';

  @override
  String get providerTesting => '正在测试连接…';

  @override
  String get providerTestSuccess => '连接成功';

  @override
  String get providerTestFailed => '连接失败,请检查 URL/API Key';

  @override
  String get providerFetching => '正在获取模型列表…';

  @override
  String providerFetchSuccess(int count) {
    return '获取到 $count 个模型';
  }

  @override
  String providerFetchFailed(String error) {
    return '获取失败: $error';
  }

  @override
  String providerModelCount(int count) {
    return '$count 个模型';
  }

  @override
  String providerCurrentModel(String model) {
    return '当前模型: $model';
  }

  @override
  String get providerSetAsDefault => '设为默认';

  @override
  String get providerTest => '测试';

  @override
  String get providerDeleteTitle => '删除提供商';

  @override
  String providerDeleteConfirm(String name) {
    return '确认删除 \"$name\"?';
  }

  @override
  String get settingsTabLocal => '本地';

  @override
  String get providerUseLocalModel => '使用本地模型';

  @override
  String get localProviderListEmpty => '还没有添加任何本地模型\n点击右下角\"新增\"加载本地 GGUF 模型';

  @override
  String get localProviderAddTitle => '新增本地模型';

  @override
  String get localProviderEditTitle => '编辑本地模型';

  @override
  String get localProviderName => '显示名称';

  @override
  String get localProviderNameHint => '例如: Qwen2.5 7B (本地)';

  @override
  String get localProviderNameRequired => '请输入显示名称';

  @override
  String get localProviderModelFile => '模型文件 (.gguf)';

  @override
  String get localProviderModelFileRequired => '请选择模型文件';

  @override
  String get localProviderPickModelFile => '选择模型文件';

  @override
  String get localProviderMmprojFile => '多模态投影 (mmproj, 可选)';

  @override
  String get localProviderPickMmproj => '选择 mmproj 文件';

  @override
  String get localProviderMmprojHint => '如果模型支持多模态,请从同目录选择对应的 mmproj-*.gguf。';

  @override
  String get localProviderAutoDetectMmproj => '从同目录自动检测';

  @override
  String get localProviderContextSize => '上下文长度';

  @override
  String get localProviderTemperature => '温度';

  @override
  String get localProviderGpuLayers => 'GPU 层数';

  @override
  String get localProviderGpuLayersHint => '0 = 仅 CPU。数值越大,卸载到 GPU 的层数越多。';

  @override
  String get localProviderMaxTokens => '最大生成 token';

  @override
  String get localProviderKvCacheK => 'KV 缓存 (K) 量化';

  @override
  String get localProviderKvCacheV => 'KV 缓存 (V) 量化';

  @override
  String get localProviderKvCacheHint =>
      'f16 = 全精度,q8_0 ≈ 内存减半,q4_0 ≈ 内存降至 1/4。非 f16 需要开启 flash attention。';

  @override
  String get localProviderBatchSize => '批大小 (n_batch)';

  @override
  String get localProviderBatchSizeHint =>
      '单次前向计算缓冲区大小。默认 512(对齐 LM Studio / Ollama)。调大可加速长 prompt 的预填充,但更占内存。';

  @override
  String get localProviderThinkingBudget => '思考块 token 上限';

  @override
  String get localProviderThinkingBudgetHint =>
      '对 Qwen3 / DeepSeek-R1 / GLM-4.5 等思考模型,限制 <think>...</think> 块最多消耗的 token。设 0 = 不限(思考模型可能把整个上下文都填进思考块,出不来最终回答)。建议 2048(4K-8K 上下文)或 4096(16K+ 上下文)。需在聊天设置里同时打开「思考模式」才会生效。';

  @override
  String get localProviderThinkingBudgetNoLimit => '不限';

  @override
  String get localProviderChipThink => '思考';

  @override
  String get localProviderChipThinkNoCap => '思考 ∞';

  @override
  String get localProviderMemTitle => '内存预估';

  @override
  String get localProviderMemModel => '模型权重';

  @override
  String get localProviderMemKv => 'KV 缓存';

  @override
  String get localProviderMemCompute => '计算缓冲';

  @override
  String get localProviderMemTotal => '预估总计';

  @override
  String get localProviderMemMissing => '选择模型文件后查看内存预估。';

  @override
  String get localProviderMemLoading => '正在读取 GGUF 文件头...';

  @override
  String get localProviderSetAsDefault => '设为默认';

  @override
  String get localProviderDeleteTitle => '删除本地模型';

  @override
  String localProviderDeleteConfirm(String name) {
    return '确认删除 \"$name\"?';
  }

  @override
  String get localProviderParams => '参数';

  @override
  String localProviderFileMissing(String path) {
    return '文件不存在: $path';
  }

  @override
  String localProviderMmprojDetected(String name) {
    return '已检测到: $name';
  }

  @override
  String get localProviderClearMmproj => '清除';

  @override
  String get localProviderChatTemplate => '模板(jinja)';

  @override
  String get localProviderChatTemplateHint =>
      '提示词模板，影响模型智商，请找到对应模型jinja文件：chat_template.jinja';

  @override
  String get localProviderChatTemplateClear => '清除';

  @override
  String get localProviderChatTemplateLoadFailed => '模板加载失败,请检查资源包。';

  @override
  String get builtinModelSectionTitle => '内置模型';

  @override
  String get builtinModelDownload => '下载';

  @override
  String get builtinModelNotConfigured => '未配置';

  @override
  String get builtinModelConfigured => '已配置';

  @override
  String get builtinModelEditTitle => '编辑内置模型';

  @override
  String get builtinModelReconfigure => '重新配置';

  @override
  String get builtinModelRedownload => '重新下载';

  @override
  String get builtinModelResume => '继续下载';

  @override
  String get builtinModelRetry => '重试';

  @override
  String get builtinModelCancelDownload => '取消下载';

  @override
  String get builtinModelDownloadRequired => '请先完成模型文件下载';

  @override
  String builtinModelApproxSize(String size) {
    return '约 $size';
  }

  @override
  String get builtinModelDownloaded => '已下载';

  @override
  String get builtinModelFiles => '模型文件';

  @override
  String get builtinModelWeightsFile => '模型权重 (.gguf)';

  @override
  String get builtinModelMmprojFile => '多模态投影 (mmproj)';

  @override
  String get builtinModelQueued => '等待上一个文件完成…';

  @override
  String get builtinModelWaiting => '尚未开始下载';

  @override
  String builtinModelProgress(String received, String total) {
    return '$received / $total';
  }

  @override
  String builtinModelProgressIndeterminate(Object received) {
    return '已下载 $received';
  }

  @override
  String builtinModelProgressWithPercent(
    String received,
    String total,
    String percent,
  ) {
    return '$received / $total ($percent%)';
  }

  @override
  String get builtinModelDeleteFileTooltip => '删除文件';

  @override
  String get builtinModelDeleteFileConfirm => '确定要删除此文件吗?删除后需要重新下载。';

  @override
  String builtinModelDownloadFailed(String error) {
    return '下载失败: $error';
  }

  @override
  String get builtinModelStatusPending => '等待中';

  @override
  String get builtinModelStatusRunning => '下载中';

  @override
  String get builtinModelStatusCompleted => '已完成';

  @override
  String get builtinModelStatusFailed => '失败';

  @override
  String get builtinModelStatusCancelled => '已取消';

  @override
  String get builtinModelStatusDownloaded => '已下载';

  @override
  String get roleListEmpty => '还没有添加任何角色\n点击右下角\"新增\"创建你的第一个角色';

  @override
  String get roleAddTitle => '新增角色';

  @override
  String get roleEditTitle => '编辑角色';

  @override
  String get roleName => '名称';

  @override
  String get roleNameHint => '例如: 翻译助手';

  @override
  String get roleNameRequired => '请输入角色名称';

  @override
  String get roleDescription => '简介';

  @override
  String get roleDescriptionHint => '一句话描述这个角色的作用';

  @override
  String get roleSystemPrompt => '系统提示词 (System Prompt)';

  @override
  String get roleSystemPromptHint => '描述角色的身份、行为、风格、规则等';

  @override
  String get roleUseRole => '使用此角色';

  @override
  String get roleUnuseRole => '取消使用';

  @override
  String get roleDeleteTitle => '删除角色';

  @override
  String roleDeleteConfirm(String name) {
    return '确认删除 \"$name\"?';
  }

  @override
  String get toolsListEmpty => '暂无内置工具';

  @override
  String get toolsMasterSwitchTitle => '使用工具';

  @override
  String get toolsMasterSwitchDescription => '所有内置工具的总开关';

  @override
  String get toolsMasterOffHint => '工具已全部关闭,模型只会用纯文字回复。';

  @override
  String get toolDescFetchWeb => '抓取并解析网页内容。';

  @override
  String get toolDescCurrentTime => '获取当前的日期与时间。';

  @override
  String get toolDescAskUser => '让模型在对话中向你提问或请你做选择。';

  @override
  String get toolDescRunCommand => '在电脑上执行命令行指令(仅桌面端)。';

  @override
  String get toolDescGetEnvironment => '查看电脑的操作系统与运行环境(仅桌面端)。';

  @override
  String get toolDescCalendar => '管理系统日历事件(仅手机,需要授权)。';

  @override
  String get toolDescReminders => '管理系统提醒与待办(仅手机,需要授权)。';

  @override
  String get toolDescNotes => '在本机创建、搜索与编辑笔记。';

  @override
  String get toolDescTasks => '维护本机的待办清单并标记完成。';

  @override
  String get toolDescMemory => '跨会话保存与检索 AI 的长期记忆。';

  @override
  String get toolDescLocation => '获取当前位置:手机用 GPS,其他平台用 IP。';

  @override
  String get toolDescDownload => '把网址里的文件下载到本地临时目录。';

  @override
  String get toolDescFile =>
      '管理设备上的文件:电脑任意路径,手机走系统文件选择器,或在用户选定的工作目录下使用相对路径(无需 Android 权限)。';

  @override
  String get toolDescSearch =>
      '用正则搜索文件内容,返回匹配的文件+行号+原文(比一个个读文件省 token)。大仓库默认跳过 .git/node_modules/二进制 等重目录。';

  @override
  String get toolDescLoadSkill => '按需读取某个技能的完整说明。';

  @override
  String get toolDescNotification => '向系统通知中心推送一条本地消息。';

  @override
  String get toolDescTimer => '在指定时间后让模型再次回复你(仅运行时有效)。';

  @override
  String get toolDescGoogleSheet => '读写你账号下的 Google 表格(仅桌面端)。';

  @override
  String get toolDescCallMcp => '调用外部 MCP 服务器上的工具。';

  @override
  String get toolNameFetchWeb => 'Fetch Web';

  @override
  String get toolNameCurrentTime => '当前时间';

  @override
  String get toolNameAskUser => '询问用户';

  @override
  String get toolNameRunCommand => '命令行执行';

  @override
  String get toolNameGetEnvironment => '环境信息';

  @override
  String get toolNameCalendar => '日历';

  @override
  String get toolNameReminders => '提醒事项';

  @override
  String get toolNameNotes => '笔记';

  @override
  String get toolNameTasks => '任务';

  @override
  String get toolNameMemory => '记忆';

  @override
  String get toolNameLocation => '位置';

  @override
  String get toolNameDownload => '下载文件';

  @override
  String get toolNameFile => '文件';

  @override
  String get toolNameSearch => '搜索';

  @override
  String get toolNameLoadSkill => '加载技能';

  @override
  String get toolNameNotification => '通知';

  @override
  String get toolNameTimer => '计时器';

  @override
  String get toolNameGoogleSheet => 'Google Sheet';

  @override
  String get toolNameCallMcp => '调用 MCP 工具';

  @override
  String get downloadStatusPending => '等待中…';

  @override
  String get downloadStatusRunning => '下载中…';

  @override
  String get downloadStatusCompleted => '已下载';

  @override
  String get downloadStatusFailed => '下载失败';

  @override
  String get downloadStatusCancelled => '已取消';

  @override
  String get downloadStatusSaved => '已保存';

  @override
  String get downloadProgressIndeterminate => '下载中…';

  @override
  String get downloadActionSave => '保存';

  @override
  String get downloadActionReveal => '打开目录';

  @override
  String get downloadActionCancel => '取消';

  @override
  String get downloadActionDiscard => '丢弃';

  @override
  String get downloadPickFolderTitle => '选择保存目录';

  @override
  String downloadSavedSnackbar(String path) {
    return '已保存到 $path';
  }

  @override
  String downloadSaveFailedSnackbar(String error) {
    return '保存失败:$error';
  }

  @override
  String get downloadDiscardedSnackbar => '已丢弃';

  @override
  String get downloadExpiredHint => '文件已不在 APP 临时目录中,请让 AI 重新下载。';

  @override
  String get remindersPickerTitle => '选择待办日历';

  @override
  String get remindersPickerDescription =>
      'Android 上的提醒会作为全天事件存放在你某个日历中。请选择 Agent Buddy 用于保存提醒事项与待办的日历。';

  @override
  String get remindersPickerEmpty => '未找到可写日历。请先在本机添加一个本地或 Google 日历,然后再试。';

  @override
  String get skillListEmpty =>
      '还没有添加任何技能\n技能可在对话时为 AI 提供额外的能力说明\n点击右下角\"新增\"开始';

  @override
  String get skillAddTitle => '新增技能';

  @override
  String get skillEditTitle => '编辑技能';

  @override
  String get skillName => '名称';

  @override
  String get skillNameHint => '例如: 代码审查';

  @override
  String get skillNameRequired => '请输入技能名称';

  @override
  String get skillDescription => '简介';

  @override
  String get skillDescriptionHint => '一句话描述这个技能的用途';

  @override
  String get skillContent => '内容 (Markdown)';

  @override
  String get skillContentHint => '技能的具体内容,使用 Markdown 格式';

  @override
  String get skillDeleteTitle => '删除技能';

  @override
  String skillDeleteConfirm(String name) {
    return '确认删除 \"$name\"?';
  }

  @override
  String get chatInputHint => '说点什么…';

  @override
  String get chatInputHintNoModel => '请先在设置中添加模型';

  @override
  String get chatInputHintReplying => '模型回复中…';

  @override
  String get chatToolsTooltip => '更多工具';

  @override
  String get chatToolImage => '图片';

  @override
  String get chatToolFile => '文件';

  @override
  String get chatToolWorkingDirectory => '工作目录';

  @override
  String get chatToolThinking => '思考模式';

  @override
  String get fileRemoveTooltip => '移除文件';

  @override
  String fileErrorFailedToAttach(String error) {
    return '添加文件失败: $error';
  }

  @override
  String workingDirectoryError(String error) {
    return '选择工作目录失败: $error';
  }

  @override
  String get workingDirectoryCancelled =>
      '用户取消了工作目录选择 — 在用户通过聊天工具栏重新选一次文件夹之前,对工作目录的文件操作都会失败。';

  @override
  String get imageAttachTooltip => '添加图片';

  @override
  String get imagePickGallery => '从相册选择';

  @override
  String get imagePickCamera => '拍照';

  @override
  String get imageRemoveTooltip => '移除图片';

  @override
  String imageErrorFailedToAttach(String error) {
    return '添加图片失败: $error';
  }

  @override
  String get messageThinking => '思考过程';

  @override
  String messageErrorPrefix(String error) {
    return '出错了: $error';
  }

  @override
  String messageMetricTtft(String seconds) {
    return '$seconds';
  }

  @override
  String messageMetricSpeed(String speed) {
    return '${speed}t/s';
  }

  @override
  String messageMetricTokensTotal(String count) {
    return '${count}token';
  }

  @override
  String get codeCopy => '复制';

  @override
  String get codeCopied => '已复制';

  @override
  String get imageLoadFailed => '图片加载失败';

  @override
  String get toolCallArguments => '参数';

  @override
  String get toolCallResult => '结果';

  @override
  String get toolCallStatusPending => '等待中';

  @override
  String get toolCallStatusRunning => '运行中';

  @override
  String get toolCallStatusSuccess => '成功';

  @override
  String get toolCallStatusFailed => '失败';

  @override
  String toolCallDurationMs(int ms) {
    return '$ms 毫秒';
  }

  @override
  String toolCallDurationSec(String sec) {
    return '$sec 秒';
  }

  @override
  String get toolCallNoArguments => '(无参数)';

  @override
  String get toolCallNoResult => '(无结果)';

  @override
  String get toolCallExpand => '展开详情';

  @override
  String get toolCallCollapse => '收起详情';

  @override
  String get toolCallRetry => '重试';

  @override
  String get toolCallRetryFailed => '重新执行该工具调用';

  @override
  String get toolCallAwaitingUser => '等待用户在系统选择器中操作…';

  @override
  String toolGroupSummary(int count) {
    return '调用了 $count 个工具';
  }

  @override
  String toolCallRetryNote(String tool, String result) {
    return '[重试 $tool] 工具返回了新的结果,请基于此继续或修正之前的回答:\n\n$result';
  }

  @override
  String get chatNoProvider => '请先在设置中添加并启用一个模型提供商。';

  @override
  String get chatNoModel => '当前提供商没有可用模型,请先在设置中获取模型列表并选择一个模型。';

  @override
  String chatRequestFailed(String error) {
    return '请求失败: $error';
  }

  @override
  String chatRetryStatus(String attempt, String seconds) {
    return '网络抖动,第 $attempt 次重试,$seconds 秒后重连';
  }

  @override
  String get generalSectionAppearance => '外观';

  @override
  String get generalDarkMode => '夜间模式';

  @override
  String get generalThemeSystem => '跟随系统';

  @override
  String get generalThemeLight => '浅色';

  @override
  String get generalThemeDark => '深色';

  @override
  String get generalSectionLanguage => '语言';

  @override
  String get generalLanguageSystem => '跟随系统';

  @override
  String get generalLanguageEn => 'English';

  @override
  String get generalLanguageZh => '中文';

  @override
  String get generalSectionAbout => '关于';

  @override
  String get generalAboutAppName => 'Agent Buddy';

  @override
  String get generalAboutTagline => '跨端智能体基座';

  @override
  String generalAboutVersion(String version) {
    return '版本 $version';
  }

  @override
  String get memoryListEmpty => '暂无记忆\nAI 会在聊天过程中把有用信息写入这里';

  @override
  String memorySearchEmpty(String keyword) {
    return '没有匹配 \"$keyword\" 的记忆';
  }

  @override
  String get memoryAddTitle => '新增记忆';

  @override
  String get memoryEditTitle => '编辑记忆';

  @override
  String get memoryContent => '内容';

  @override
  String get memoryContentHint => '一段独立、简洁的事实,可在未来会话中被引用';

  @override
  String get memoryContentRequired => '请输入内容';

  @override
  String get memorySourceAi => 'AI';

  @override
  String get memorySourceUser => '用户';

  @override
  String get memoryDeleteTitle => '删除记忆';

  @override
  String get memoryDeleteConfirm => '确认删除这条记忆?';

  @override
  String memoryDeleteBatchConfirmTitle(int count) {
    return '确认删除 $count 条记忆?';
  }

  @override
  String get memoryDeleteBatchMessage => '所选记忆将被删除,且无法恢复。';

  @override
  String get memorySearch => '搜索';

  @override
  String get memorySearchClear => '清除';

  @override
  String get memorySelectAll => '全选';

  @override
  String get memoryDeselectAll => '取消全选';

  @override
  String get memoryEdit => '编辑';

  @override
  String get memoryJustNow => '刚刚';

  @override
  String memoryMinutesAgo(int n) {
    return '$n 分钟前';
  }

  @override
  String memoryHoursAgo(int n) {
    return '$n 小时前';
  }

  @override
  String memoryDaysAgo(int n) {
    return '$n 天前';
  }

  @override
  String get locationPermissionDenied => '位置权限被拒绝,请在系统设置中授予权限。';

  @override
  String get locationPermanentlyDenied => '位置权限已被永久拒绝,请打开系统设置启用。';

  @override
  String get locationUnavailable => '无法获取位置,请确认定位服务已开启后重试。';

  @override
  String get locationTimeout => '位置请求超时,请重试。';

  @override
  String get settingsTabTimers => '计时任务';

  @override
  String get timerListEmpty => '暂无计时任务\n让 AI 用 \"timer\" 工具设置一个稍后回来的提醒';

  @override
  String get timerListEmptyFilter => '没有匹配的计时任务';

  @override
  String get timerAddTitle => '新增计时';

  @override
  String get timerEditTitle => '编辑计时';

  @override
  String get timerFieldLabel => '标题';

  @override
  String get timerFieldLabelHint => '例如: 喝水';

  @override
  String get timerFieldLabelRequired => '请输入标题';

  @override
  String get timerFieldDelay => '延迟(秒)';

  @override
  String get timerFieldDelayHint => '例如: 300 = 5 分钟';

  @override
  String get timerFieldDelayInvalid => '延迟必须是非负整数';

  @override
  String get timerFieldPrompt => '提醒正文';

  @override
  String get timerFieldPromptHint => '可选。会成为系统通知的正文,也会回传给 AI。';

  @override
  String get timerFieldActionHint => 'AI 提示';

  @override
  String get timerFieldActionHintHint =>
      '可选。告诉 AI 触发时该做什么(例如: \"调用 notification 工具通知用户\")。';

  @override
  String get timerFieldFireAt => '触发时间 (ISO 8601)';

  @override
  String get timerFieldFireAtHint => '可选。绝对触发时刻(优先于延迟)。';

  @override
  String get timerStatusPending => '等待中';

  @override
  String get timerStatusFired => '已触发';

  @override
  String get timerStatusCancelled => '已取消';

  @override
  String get timerActionEdit => '编辑';

  @override
  String get timerActionCancel => '取消';

  @override
  String get timerActionDelete => '删除';

  @override
  String get timerActionRestore => '重新激活';

  @override
  String get timerCancelConfirmTitle => '取消计时?';

  @override
  String timerCancelConfirmMessage(Object label) {
    return '待触发任务 \"$label\" 将被取消,不会响。';
  }

  @override
  String get timerDeleteConfirmTitle => '删除计时?';

  @override
  String get timerDeleteConfirmMessage => '该计时记录将从列表中移除,且无法恢复。';

  @override
  String get timerShowAll => '显示全部(含已触发 / 已取消)';

  @override
  String get timerHideTerminal => '隐藏已触发 / 已取消';

  @override
  String timerFiresIn(String duration) {
    return '$duration 后触发';
  }

  @override
  String timerFiredAt(String when) {
    return '$when 触发';
  }

  @override
  String get timerSourceAi => 'AI';

  @override
  String get timerSourceUser => '用户';

  @override
  String get timerNoteRuntime => '计时器只在 App 运行期间有效;App 被杀或后台时不会响。';

  @override
  String foregroundTimerTitleOne(String label) {
    return '1 个计时任务: $label';
  }

  @override
  String foregroundTimerTitleMany(int count) {
    return '$count 个计时任务';
  }

  @override
  String get mcpListEmpty => '还没有添加任何 MCP 服务器\n点击右下角\"新增\"添加 MCP 配置';

  @override
  String get mcpAddTitle => '新增 MCP';

  @override
  String get mcpEditTitle => '编辑 MCP';

  @override
  String get mcpName => '名称';

  @override
  String get mcpNameHint => '例如: 文件系统服务器';

  @override
  String get mcpNameRequired => '请输入 MCP 名称';

  @override
  String get mcpJsonConfig => 'MCP 配置 (JSON)';

  @override
  String get mcpJsonConfigHint =>
      '粘贴 MCP 服务器配置。HTTP: JSON 含 url/headers 字段,或直接贴 URL。Stdio: JSON 含 command/args/env。支持 mcpServers 包装格式。';

  @override
  String get mcpJsonConfigRequired => '请输入 MCP 配置';

  @override
  String get mcpDeleteTitle => '删除 MCP';

  @override
  String mcpDeleteConfirm(Object name) {
    return '确认删除 \"$name\"?';
  }

  @override
  String get mcpTestConnection => '测试连接';

  @override
  String get mcpTesting => '正在测试连接…';

  @override
  String get mcpTestSuccess => '连接成功';

  @override
  String get mcpTestFailed => '连接失败';

  @override
  String get googleSheetSheetTitle => 'Google Sheet';

  @override
  String get googleSheetSheetSubtitle =>
      '通过 OAuth 把 Agent Buddy 接入 Google Sheet,让模型可以读写你指定的表格。';

  @override
  String get googleSheetInputLabel => 'Google Sheet 链接或 ID';

  @override
  String get googleSheetInputHint =>
      'https://docs.google.com/spreadsheets/d/…/edit   或直接粘贴 ID';

  @override
  String get googleSheetTestButton => '测试连接';

  @override
  String get googleSheetTestAuthorizing => '正在浏览器中授权…';

  @override
  String get googleSheetDefaultTabLabel => '默认表(模型未指定 tab 时用这张)';

  @override
  String get googleSheetRefreshButton => '刷新表格';

  @override
  String get googleSheetEmptyTabs => '点击刷新从表格拉取表名。';

  @override
  String get googleSheetEmptyTabsUnauthorized => '请先授权后加载表名。';

  @override
  String get googleSheetSignOut => '退出登录';

  @override
  String get googleSheetStatusUnconfigured => '未配置';

  @override
  String get googleSheetStatusUnauthorized => '未授权 — 点击测试连接';

  @override
  String get googleSheetStatusAuthorizing => '等待浏览器回调…';

  @override
  String get googleSheetStatusAuthorized => '已连接';

  @override
  String googleSheetStatusAuthorizedAs(String email) {
    return '已连接:$email';
  }

  @override
  String get googleSheetStatusError => '授权出错';
}
