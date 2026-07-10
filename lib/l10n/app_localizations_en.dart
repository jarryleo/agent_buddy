// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Agent Buddy';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonSave => 'Save';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonInUse => 'In use';

  @override
  String get commonError => 'Error';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get homeSettingsTooltip => 'Settings';

  @override
  String get homeClearChatTooltip => 'Clear chat';

  @override
  String get homeClearChatTitle => 'Clear chat';

  @override
  String get homeClearChatMessage =>
      'Clear all messages? This action cannot be undone.';

  @override
  String get homeClearChatConfirm => 'Clear';

  @override
  String get homeEmptyTitle => 'Agent Buddy';

  @override
  String get homeEmptySubtitle =>
      'Tap the settings button in the top left to add a model provider and a role to start chatting.';

  @override
  String get homeSessionsTooltip => 'Sessions';

  @override
  String get sessionManagerTitle => 'Sessions';

  @override
  String get sessionManagerNew => 'New chat';

  @override
  String get sessionManagerEmpty => 'No saved sessions yet.';

  @override
  String get sessionManagerSelectAll => 'Select all';

  @override
  String get sessionManagerDeselectAll => 'Deselect all';

  @override
  String get sessionManagerDelete => 'Delete';

  @override
  String get sessionManagerDeleteConfirmTitle => 'Delete session?';

  @override
  String sessionManagerDeleteBatchConfirmTitle(int count) {
    return 'Delete $count sessions?';
  }

  @override
  String get sessionManagerDeleteMessage =>
      'The selected conversations will be removed. This action cannot be undone.';

  @override
  String get homeNoModel => 'No model configured';

  @override
  String get homeNoModelSelected => 'No model selected';

  @override
  String homeProviderModel(String provider, String model) {
    return '$provider · $model';
  }

  @override
  String get homeCopied => 'Copied';

  @override
  String get homeLocalModelLoading => 'Loading model…';

  @override
  String get homeLocalModelReady => 'Model loaded';

  @override
  String get homeLocalModelRelease => 'Release model';

  @override
  String get homeLocalModelReleaseTooltip => 'Free the local model from memory';

  @override
  String get homeLocalModelReleased => 'Model released';

  @override
  String homeLocalModelLoadFailed(String error) {
    return 'Failed to load model: $error';
  }

  @override
  String get homeLocalModelRetry => 'Retry';

  @override
  String get homeLocalModelDismiss => 'Dismiss';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsTabGeneral => 'General';

  @override
  String get settingsTabProvider => 'Models';

  @override
  String get settingsTabRole => 'Role';

  @override
  String get settingsTabTools => 'Tools';

  @override
  String get settingsTabSkill => 'Skill';

  @override
  String get settingsTabMemory => 'Memory';

  @override
  String get providerListEmpty =>
      'No model providers added yet.\nTap \"Add\" in the bottom right to start.';

  @override
  String get providerAddTitle => 'Add Provider';

  @override
  String get providerEditTitle => 'Edit Provider';

  @override
  String get providerProtocol => 'Protocol';

  @override
  String get providerProtocolOpenAI => 'OpenAI';

  @override
  String get providerProtocolAnthropic => 'Anthropic';

  @override
  String get providerName => 'Name';

  @override
  String get providerNameHint => 'e.g. OpenAI Official';

  @override
  String get providerNameRequired => 'Please enter a name';

  @override
  String get providerBaseUrl => 'Base URL';

  @override
  String get providerBaseUrlHint => 'https://api.openai.com';

  @override
  String get providerBaseUrlRequired => 'Please enter a Base URL';

  @override
  String get providerApiKey => 'API Key';

  @override
  String get providerApiKeyRequired => 'Please enter an API Key';

  @override
  String get providerChatPath => 'Chat Path';

  @override
  String get providerChatPathHelper =>
      'Auto-filled based on protocol, usually no need to modify';

  @override
  String get providerChatPathRequired => 'Please enter a Chat Path';

  @override
  String get providerTestConnection => 'Test connection';

  @override
  String get providerFetchModels => 'Fetch models';

  @override
  String get providerSelectModel => 'Select default model';

  @override
  String get providerTesting => 'Testing connection…';

  @override
  String get providerTestSuccess => 'Connected successfully';

  @override
  String get providerTestFailed =>
      'Connection failed, please check URL/API Key';

  @override
  String get providerFetching => 'Fetching model list…';

  @override
  String providerFetchSuccess(int count) {
    return 'Fetched $count models';
  }

  @override
  String providerFetchFailed(String error) {
    return 'Fetch failed: $error';
  }

  @override
  String providerModelCount(int count) {
    return '$count models';
  }

  @override
  String providerCurrentModel(String model) {
    return 'Current model: $model';
  }

  @override
  String get providerSetAsDefault => 'Set as default';

  @override
  String get providerTest => 'Test';

  @override
  String get providerDeleteTitle => 'Delete Provider';

  @override
  String providerDeleteConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get settingsTabLocal => 'Local';

  @override
  String get providerUseLocalModel => 'Use a local model instead';

  @override
  String get localProviderListEmpty =>
      'No local models added yet.\nTap \"Add\" in the bottom right to load a GGUF model from disk.';

  @override
  String get localProviderAddTitle => 'Add Local Model';

  @override
  String get localProviderEditTitle => 'Edit Local Model';

  @override
  String get localProviderName => 'Display name';

  @override
  String get localProviderNameHint => 'e.g. Qwen2.5 7B (Local)';

  @override
  String get localProviderNameRequired => 'Please enter a display name';

  @override
  String get localProviderModelFile => 'Model file (.gguf)';

  @override
  String get localProviderModelFileRequired => 'Please pick a model file';

  @override
  String get localProviderPickModelFile => 'Pick model file';

  @override
  String get localProviderMmprojFile =>
      'Multimodal projector (mmproj, optional)';

  @override
  String get localProviderPickMmproj => 'Pick mmproj file';

  @override
  String get localProviderMmprojHint =>
      'If the model is multimodal, pick a matching mmproj-*.gguf from the same directory.';

  @override
  String get localProviderAutoDetectMmproj => 'Auto-detect from same directory';

  @override
  String get localProviderContextSize => 'Context size';

  @override
  String get localProviderTemperature => 'Temperature';

  @override
  String get localProviderGpuLayers => 'GPU layers';

  @override
  String get localProviderGpuLayersHint =>
      '0 = CPU only. Higher values offload more layers to GPU.';

  @override
  String get localProviderMaxTokens => 'Max generated tokens';

  @override
  String get localProviderKvCacheK => 'KV cache (K) quantization';

  @override
  String get localProviderKvCacheV => 'KV cache (V) quantization';

  @override
  String get localProviderKvCacheHint =>
      'f16 = full quality, q8_0 ≈ 0.5× memory, q4_0 ≈ 0.25×. Non-f16 requires flash attention.';

  @override
  String get localProviderBatchSize => 'Batch size (n_batch)';

  @override
  String get localProviderBatchSizeHint =>
      'Per-step compute buffer. Default 512 (matches LM Studio / Ollama). Raising it speeds up prefill of long prompts but uses more memory.';

  @override
  String get localProviderMemTitle => 'Memory estimate';

  @override
  String get localProviderMemModel => 'Model weights';

  @override
  String get localProviderMemKv => 'KV cache';

  @override
  String get localProviderMemCompute => 'Compute buffer';

  @override
  String get localProviderMemTotal => 'Estimated total';

  @override
  String get localProviderMemMissing =>
      'Pick a model file to see the memory estimate.';

  @override
  String get localProviderMemLoading => 'Reading GGUF header...';

  @override
  String get localProviderSetAsDefault => 'Set as default';

  @override
  String get localProviderDeleteTitle => 'Delete Local Model';

  @override
  String localProviderDeleteConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get localProviderParams => 'Parameters';

  @override
  String localProviderFileMissing(String path) {
    return 'File not found: $path';
  }

  @override
  String localProviderMmprojDetected(String name) {
    return 'Detected: $name';
  }

  @override
  String get localProviderClearMmproj => 'Clear';

  @override
  String get roleListEmpty =>
      'No roles added yet.\nTap \"Add\" in the bottom right to create your first role.';

  @override
  String get roleAddTitle => 'Add Role';

  @override
  String get roleEditTitle => 'Edit Role';

  @override
  String get roleName => 'Name';

  @override
  String get roleNameHint => 'e.g. Translation assistant';

  @override
  String get roleNameRequired => 'Please enter a role name';

  @override
  String get roleDescription => 'Description';

  @override
  String get roleDescriptionHint =>
      'A short description of what this role does';

  @override
  String get roleSystemPrompt => 'System Prompt';

  @override
  String get roleSystemPromptHint =>
      'Describe the role\'s identity, behavior, style and rules';

  @override
  String get roleUseRole => 'Use this role';

  @override
  String get roleUnuseRole => 'Stop using';

  @override
  String get roleDeleteTitle => 'Delete Role';

  @override
  String roleDeleteConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get toolsListEmpty => 'No built-in tools';

  @override
  String get toolFetchWebName => 'Fetch Web';

  @override
  String get toolFetchWebDescription =>
      'Fetch the content of a URL and return the plain text of the page.';

  @override
  String get toolCurrentTimeName => 'Current Time';

  @override
  String get toolCurrentTimeDescription =>
      'Get the current date and time as local time, ISO 8601, and Unix timestamp.';

  @override
  String get toolAskUserName => 'Ask User';

  @override
  String get toolAskUserDescription =>
      'Ask the user a multiple-choice or single-choice question. The user\'s selection is returned to the model.';

  @override
  String get toolRunCommandName => 'Run Command';

  @override
  String get toolRunCommandDescription =>
      'Execute a shell command on the host. Returns stdout, stderr, and exit code. Desktop only (Windows / macOS / Linux).';

  @override
  String get toolGetEnvironmentName => 'Get Environment';

  @override
  String get toolGetEnvironmentDescription =>
      'Get local system information (OS, architecture, user, home directory, shell, kernel version) so the model can pick platform-specific commands. Desktop only (Windows / macOS / Linux).';

  @override
  String get toolCalendarName => 'Calendar';

  @override
  String get toolCalendarDescription =>
      'Manage the phone\'s system calendar (list, get, create, update, delete events). Requires calendar read/write permission. Android / iOS only.';

  @override
  String get toolRemindersName => 'Reminders';

  @override
  String get toolRemindersDescription =>
      'Manage reminders and to-dos (iOS: Reminders framework; Android: all-day calendar events). Requires reminders / calendar write permission. Android / iOS only.';

  @override
  String get toolNotesName => 'Notes';

  @override
  String get toolNotesDescription =>
      'Manage Agent Buddy\'s built-in notes (stored locally in Hive, no system permission required).';

  @override
  String get toolTasksName => 'Tasks';

  @override
  String get toolTasksDescription =>
      'Manage Agent Buddy\'s built-in task list (stored locally in Hive, no system permission required). On Android, this also acts as the fallback for the Reminders tool.';

  @override
  String get remindersPickerTitle => 'Choose a todo calendar';

  @override
  String get remindersPickerDescription =>
      'Android stores reminders as all-day events in one of your calendars. Pick the calendar Agent Buddy should use to save your reminders and to-dos.';

  @override
  String get remindersPickerEmpty =>
      'No writable calendar found. Add a local or Google calendar on this device first, then come back.';

  @override
  String get skillListEmpty =>
      'No skills added yet.\nSkills provide extra instructions to the AI during chat.\nTap \"Add\" in the bottom right to start.';

  @override
  String get skillAddTitle => 'Add Skill';

  @override
  String get skillEditTitle => 'Edit Skill';

  @override
  String get skillName => 'Name';

  @override
  String get skillNameHint => 'e.g. Code review';

  @override
  String get skillNameRequired => 'Please enter a skill name';

  @override
  String get skillDescription => 'Description';

  @override
  String get skillDescriptionHint =>
      'A short description of what this skill does';

  @override
  String get skillContent => 'Content (Markdown)';

  @override
  String get skillContentHint => 'Skill content in Markdown format';

  @override
  String get skillDeleteTitle => 'Delete Skill';

  @override
  String skillDeleteConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get chatInputHint => 'Say something…';

  @override
  String get chatInputHintNoModel => 'Please add a model in settings first';

  @override
  String get chatInputHintReplying => 'Model is replying…';

  @override
  String get imageAttachTooltip => 'Attach image';

  @override
  String get imagePickGallery => 'Choose from gallery';

  @override
  String get imagePickCamera => 'Take a photo';

  @override
  String get imageRemoveTooltip => 'Remove image';

  @override
  String imageErrorFailedToAttach(String error) {
    return 'Failed to attach image: $error';
  }

  @override
  String get messageThinking => 'Thinking';

  @override
  String messageErrorPrefix(String error) {
    return 'Error: $error';
  }

  @override
  String get codeCopy => 'Copy';

  @override
  String get codeCopied => 'Copied';

  @override
  String get imageLoadFailed => 'Failed to load image';

  @override
  String get toolCallArguments => 'Arguments';

  @override
  String get toolCallResult => 'Result';

  @override
  String get toolCallStatusPending => 'Pending';

  @override
  String get toolCallStatusRunning => 'Running';

  @override
  String get toolCallStatusSuccess => 'Success';

  @override
  String get toolCallStatusFailed => 'Failed';

  @override
  String toolCallDurationMs(int ms) {
    return '$ms ms';
  }

  @override
  String toolCallDurationSec(String sec) {
    return '${sec}s';
  }

  @override
  String get toolCallNoArguments => '(no arguments)';

  @override
  String get toolCallNoResult => '(no result)';

  @override
  String get toolCallExpand => 'Show details';

  @override
  String get toolCallCollapse => 'Hide details';

  @override
  String get toolCallRetry => 'Retry';

  @override
  String get toolCallRetryFailed => 'Retry this tool call';

  @override
  String toolCallRetryNote(String tool, String result) {
    return '[Retry of $tool] The tool returned the following new result. Please use it to continue or correct your previous answer:\n\n$result';
  }

  @override
  String get chatNoProvider =>
      'Please add and enable a model provider in settings first.';

  @override
  String get chatNoModel =>
      'No model is available for the current provider. Please fetch and select a model in settings.';

  @override
  String chatRequestFailed(String error) {
    return 'Request failed: $error';
  }

  @override
  String get generalSectionAppearance => 'Appearance';

  @override
  String get generalDarkMode => 'Dark mode';

  @override
  String get generalThemeSystem => 'Follow system';

  @override
  String get generalThemeLight => 'Light';

  @override
  String get generalThemeDark => 'Dark';

  @override
  String get generalSectionLanguage => 'Language';

  @override
  String get generalLanguageSystem => 'Follow system';

  @override
  String get generalLanguageEn => 'English';

  @override
  String get generalLanguageZh => '中文';

  @override
  String get generalSectionAbout => 'About';

  @override
  String get generalAboutAppName => 'Agent Buddy';

  @override
  String get generalAboutTagline => 'Cross-platform agent hub';

  @override
  String generalAboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get memoryListEmpty =>
      'No memories yet.\nThe AI will write useful information here as you chat.';

  @override
  String memorySearchEmpty(String keyword) {
    return 'No memories match \"$keyword\".';
  }

  @override
  String get memoryAddTitle => 'Add Memory';

  @override
  String get memoryEditTitle => 'Edit Memory';

  @override
  String get memoryContent => 'Content';

  @override
  String get memoryContentHint =>
      'A short, self-contained fact that will be remembered across sessions.';

  @override
  String get memoryContentRequired => 'Please enter the content';

  @override
  String get memorySourceAi => 'AI';

  @override
  String get memorySourceUser => 'User';

  @override
  String get memoryDeleteTitle => 'Delete Memory';

  @override
  String get memoryDeleteConfirm => 'Delete this memory?';

  @override
  String memoryDeleteBatchConfirmTitle(int count) {
    return 'Delete $count memories?';
  }

  @override
  String get memoryDeleteBatchMessage =>
      'The selected memories will be removed. This action cannot be undone.';

  @override
  String get memorySearch => 'Search';

  @override
  String get memorySearchClear => 'Clear';

  @override
  String get memorySelectAll => 'Select all';

  @override
  String get memoryDeselectAll => 'Deselect all';

  @override
  String get memoryEdit => 'Edit';

  @override
  String get memoryJustNow => 'just now';

  @override
  String memoryMinutesAgo(int n) {
    return '$n min ago';
  }

  @override
  String memoryHoursAgo(int n) {
    return '$n h ago';
  }

  @override
  String memoryDaysAgo(int n) {
    return '$n d ago';
  }

  @override
  String get locationPermissionDenied =>
      'Location permission denied. Please grant it in system settings.';

  @override
  String get locationPermanentlyDenied =>
      'Location permission permanently denied. Open system settings to enable it.';

  @override
  String get locationUnavailable =>
      'Location unavailable. Make sure location services are on and try again.';

  @override
  String get locationTimeout => 'Location request timed out. Please try again.';
}
