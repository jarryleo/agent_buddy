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
  String get toolFetchWebName => 'Fetch Web';

  @override
  String get toolFetchWebDescription => '获取指定网址的内容,返回网页的纯文本。';

  @override
  String get toolCurrentTimeName => '当前时间';

  @override
  String get toolCurrentTimeDescription =>
      '获取当前日期与时间,返回本地时间、ISO 8601 与 Unix 时间戳。';

  @override
  String get toolAskUserName => '询问用户';

  @override
  String get toolAskUserDescription => '向用户提出一个多选或单选问题,用户作答后把结果回传给模型。';

  @override
  String get toolRunCommandName => '命令行执行';

  @override
  String get toolRunCommandDescription =>
      '在主机上执行 shell 命令,返回 stdout、stderr 与退出码。仅桌面端可用 (Windows / macOS / Linux)。';

  @override
  String get toolGetEnvironmentName => '环境信息';

  @override
  String get toolGetEnvironmentDescription =>
      '获取本机环境信息(操作系统、架构、用户、主目录、shell、内核版本),供模型在执行命令行前判断平台特定命令。仅桌面端可用 (Windows / macOS / Linux)。';

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
}
