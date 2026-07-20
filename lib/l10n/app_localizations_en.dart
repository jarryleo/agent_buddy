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
  String get settingsTabMcp => 'MCP';

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
  String get providerSupportedFileTypes => 'Supported file types';

  @override
  String get providerSupportedFileTypesHelper =>
      'Picked files in these categories are sent inline to the model. Other files are forwarded as path-only references so the model can read them via the file tool.';

  @override
  String get providerFileTypeText => 'Text';

  @override
  String get providerFileTypeImage => 'Image';

  @override
  String get providerFileTypeAudio => 'Audio';

  @override
  String get providerFileTypeVideo => 'Video';

  @override
  String get providerFileTypeDocument => 'Document';

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
  String get localProviderThinkingBudget => 'Reasoning budget (tokens)';

  @override
  String get localProviderThinkingBudgetHint =>
      'For thinking models (Qwen3 / DeepSeek-R1 / GLM-4.5 / MagiStral / …), caps the <think>...</think> block at this many tokens. 0 = no cap — the model can spend the entire context on chain-of-thought and never produce a real answer. 2048 is a good default for 4K–8K context, 4096 for 16K+. Only takes effect when thinking mode is also enabled in chat settings.';

  @override
  String get localProviderThinkingBudgetNoLimit => 'No cap';

  @override
  String get localProviderChipThink => 'think';

  @override
  String get localProviderChipThinkNoCap => 'think ∞';

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
  String get localProviderChatTemplate => 'Template (jinja)';

  @override
  String get localProviderChatTemplateHint =>
      'Prompt template — directly affects model quality. Find the matching chat_template.jinja for your model and paste it here. Leave empty to use the template embedded in the GGUF.';

  @override
  String get localProviderChatTemplateClear => 'Clear';

  @override
  String get localProviderChatTemplateLoadFailed =>
      'Failed to load template. Check the asset bundle.';

  @override
  String get builtinModelSectionTitle => 'Built-in Models';

  @override
  String get builtinModelDownload => 'Download';

  @override
  String get builtinModelNotConfigured => 'Not configured';

  @override
  String get builtinModelConfigured => 'Configured';

  @override
  String get builtinModelEditTitle => 'Edit Built-in Model';

  @override
  String get builtinModelReconfigure => 'Re-configure';

  @override
  String get builtinModelRedownload => 'Re-download';

  @override
  String get builtinModelResume => 'Resume';

  @override
  String get builtinModelRetry => 'Retry';

  @override
  String get builtinModelCancelDownload => 'Cancel download';

  @override
  String get builtinModelDownloadRequired =>
      'Please complete the model download first';

  @override
  String builtinModelApproxSize(String size) {
    return 'approx. $size';
  }

  @override
  String get builtinModelDownloaded => 'Downloaded';

  @override
  String get builtinModelFiles => 'Model files';

  @override
  String get builtinModelWeightsFile => 'Model weights (.gguf)';

  @override
  String get builtinModelMmprojFile => 'Multimodal projector (mmproj)';

  @override
  String get builtinModelQueued => 'Waiting for the previous file…';

  @override
  String get builtinModelWaiting => 'Not started yet';

  @override
  String builtinModelProgress(String received, String total) {
    return '$received / $total';
  }

  @override
  String builtinModelProgressIndeterminate(Object received) {
    return '$received downloaded';
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
  String get builtinModelDeleteFileTooltip => 'Delete file';

  @override
  String get builtinModelDeleteFileConfirm =>
      'Delete this file? You\'ll need to re-download it.';

  @override
  String builtinModelDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get builtinModelStatusPending => 'Pending';

  @override
  String get builtinModelStatusRunning => 'Downloading';

  @override
  String get builtinModelStatusCompleted => 'Done';

  @override
  String get builtinModelStatusFailed => 'Failed';

  @override
  String get builtinModelStatusCancelled => 'Cancelled';

  @override
  String get builtinModelStatusDownloaded => 'Downloaded';

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
  String get toolsMasterSwitchTitle => 'Use Tools';

  @override
  String get toolsMasterSwitchDescription =>
      'Master switch for all built-in tools.';

  @override
  String get toolsMasterOffHint =>
      'All tools are off. The model will reply in plain text only.';

  @override
  String get toolDescFetchWeb => 'Fetch and parse web pages.';

  @override
  String get toolDescCurrentTime => 'Get the current date and time.';

  @override
  String get toolDescAskUser =>
      'Let the model ask you a question or pick from options mid-chat.';

  @override
  String get toolDescRunCommand =>
      'Run shell commands on the computer (desktop only).';

  @override
  String get toolDescGetEnvironment =>
      'Inspect the host OS and runtime (desktop only).';

  @override
  String get toolDescCalendar =>
      'Manage system calendar events (mobile only, needs permission).';

  @override
  String get toolDescReminders =>
      'Manage system reminders and to-dos (mobile only, needs permission).';

  @override
  String get toolDescNotes =>
      'Create, search and edit notes stored on this device.';

  @override
  String get toolDescTasks =>
      'Maintain a local to-do list and mark items done.';

  @override
  String get toolDescMemory =>
      'Save and recall the AI\'s long-term memory across chats.';

  @override
  String get toolDescLocation =>
      'Get a coarse current location — GPS on mobile, IP elsewhere.';

  @override
  String get toolDescDownload =>
      'Stream a file from a URL into a local temp file.';

  @override
  String get toolDescFile =>
      'Manage device files — any path on desktop; on mobile: system file picker + relative paths inside the user-selected working directory (no Android runtime permission needed).';

  @override
  String get toolDescSearch =>
      'Regex-search file contents across a directory or a list of files; returns file + line + column + matched text. Skips heavy dirs (.git/node_modules/binaries) by default so large repos stay fast.';

  @override
  String get toolDescLoadSkill =>
      'Pull a skill\'s full instructions on demand.';

  @override
  String get toolDescNotification =>
      'Send a local notification via the system notification center.';

  @override
  String get toolDescTimer =>
      'Schedule a delayed callback to the model (only while the app is running).';

  @override
  String get toolDescGoogleSheet =>
      'Read and edit your Google Sheet (desktop only).';

  @override
  String get toolDescCallMcp => 'Call tools on a configured MCP server.';

  @override
  String get toolDescSubAgent =>
      'Delegate a self-contained research / information-gathering task to an isolated sub-agent that runs in its own context window and returns a compressed report. Keeps the main conversation clean and saves tokens.';

  @override
  String get toolDescEditImage =>
      'Compress, crop, resize, rotate, or convert the format of an image the user uploaded in this chat. Each call processes a copy in the temp directory — the original is never modified.';

  @override
  String get toolNameFetchWeb => 'Fetch Web';

  @override
  String get toolNameCurrentTime => 'Current Time';

  @override
  String get toolNameAskUser => 'Ask User';

  @override
  String get toolNameRunCommand => 'Run Command';

  @override
  String get toolNameGetEnvironment => 'Environment';

  @override
  String get toolNameCalendar => 'Calendar';

  @override
  String get toolNameReminders => 'Reminders';

  @override
  String get toolNameNotes => 'Notes';

  @override
  String get toolNameTasks => 'Tasks';

  @override
  String get toolNameMemory => 'Memory';

  @override
  String get toolNameLocation => 'Location';

  @override
  String get toolNameDownload => 'Download';

  @override
  String get toolNameFile => 'Files';

  @override
  String get toolNameSearch => 'Search';

  @override
  String get toolNameLoadSkill => 'Load Skill';

  @override
  String get toolNameNotification => 'Notifications';

  @override
  String get toolNameTimer => 'Timer';

  @override
  String get toolNameGoogleSheet => 'Google Sheet';

  @override
  String get toolNameCallMcp => 'MCP Tools';

  @override
  String get toolNameSubAgent => 'Sub-Agent';

  @override
  String get toolNameEditImage => 'Edit Image';

  @override
  String get downloadStatusPending => 'Waiting…';

  @override
  String get downloadStatusRunning => 'Downloading…';

  @override
  String get downloadStatusCompleted => 'Downloaded';

  @override
  String get downloadStatusFailed => 'Download failed';

  @override
  String get downloadStatusCancelled => 'Cancelled';

  @override
  String get downloadStatusSaved => 'Saved';

  @override
  String get downloadProgressIndeterminate => 'Downloading…';

  @override
  String get downloadActionSave => 'Save';

  @override
  String get downloadActionReveal => 'Open folder';

  @override
  String get downloadActionCancel => 'Cancel';

  @override
  String get downloadActionDiscard => 'Discard';

  @override
  String get downloadPickFolderTitle => 'Choose a folder to save the file in';

  @override
  String downloadSavedSnackbar(String path) {
    return 'Saved to $path';
  }

  @override
  String downloadSaveFailedSnackbar(String error) {
    return 'Save failed: $error';
  }

  @override
  String get downloadDiscardedSnackbar => 'Discarded';

  @override
  String get downloadExpiredHint =>
      'This file is no longer in the app\'s temp directory. Ask the AI to re-download.';

  @override
  String get editImageActionCompress => 'Compress';

  @override
  String get editImageActionCrop => 'Crop';

  @override
  String get editImageActionResize => 'Resize';

  @override
  String get editImageActionRotate => 'Rotate';

  @override
  String get editImageActionConvert => 'Convert';

  @override
  String get editImageActionSave => 'Save image';

  @override
  String get editImagePickFolderTitle =>
      'Choose a folder to save the edited image in';

  @override
  String editImageSavedSnackbar(String path) {
    return 'Saved to $path';
  }

  @override
  String editImageSaveFailedSnackbar(String error) {
    return 'Save failed: $error';
  }

  @override
  String get editImageExpired =>
      'This image is no longer in the app\'s temp directory. Ask the AI to re-edit it.';

  @override
  String editImageDeltaSaved(String percent) {
    return '−$percent%';
  }

  @override
  String editImageDeltaGrew(String percent) {
    return '+$percent%';
  }

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
  String get chatToolsTooltip => 'More tools';

  @override
  String get chatToolImage => 'Image';

  @override
  String get chatToolFile => 'File';

  @override
  String get chatToolWorkingDirectory => 'Workdir';

  @override
  String get chatToolThinking => 'Thinking';

  @override
  String get chatMicTooltip => 'Hold to talk';

  @override
  String get chatMicListeningHint => 'Listening… release to stop';

  @override
  String get chatVoiceDragToCancel => 'Release to cancel';

  @override
  String get chatVoicePermissionDenied =>
      'Microphone permission denied. Please grant it in system settings to use voice input.';

  @override
  String get chatVoicePermanentlyDenied =>
      'Microphone permission permanently denied. Open system settings to enable voice input.';

  @override
  String get chatVoiceUnavailable =>
      'No system speech recognition service was found. Enable one in system settings or install a speech service, then try again.';

  @override
  String get chatVoiceListenFailed =>
      'Couldn\'t start voice input. Please try again.';

  @override
  String get chatVoiceTooShort => 'No speech detected. Try again.';

  @override
  String get fileRemoveTooltip => 'Remove file';

  @override
  String fileErrorFailedToAttach(String error) {
    return 'Failed to attach file: $error';
  }

  @override
  String workingDirectoryError(String error) {
    return 'Failed to choose working directory: $error';
  }

  @override
  String get workingDirectoryCancelled =>
      'Working directory selection was cancelled — file operations against the working directory will keep failing until the user picks a folder via the chat toolbar.';

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
  String get chatMentionPopupTitle => 'Files in working directory';

  @override
  String get chatMentionPopupHint =>
      'Type to filter; ↑/↓ to pick; Enter to attach the first match.';

  @override
  String get chatMentionPopupEmpty =>
      'No matching files in the working directory.';

  @override
  String get chatMentionPopupNoWorkingDir =>
      'Pick a working directory in the chat toolbar to use @ mentions.';

  @override
  String get chatMentionAttachedAsImage => 'Image';

  @override
  String get chatMentionAttachedAsFile => 'File';

  @override
  String get messageThinking => 'Thinking';

  @override
  String messageErrorPrefix(String error) {
    return 'Error: $error';
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
  String get codeCopy => 'Copy';

  @override
  String get codeCopied => 'Copied';

  @override
  String get imageLoadFailed => 'Failed to load image';

  @override
  String get chatTtsSpeak => 'Read aloud';

  @override
  String get chatTtsStop => 'Stop reading';

  @override
  String get chatTtsUnavailable =>
      'Text-to-speech is not supported on this device.';

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
  String get toolCallAwaitingUser =>
      'Waiting for the user in the system picker…';

  @override
  String toolGroupSummary(int count) {
    return '$count tool calls';
  }

  @override
  String get askUserQuestionPrompt => 'Model asks:';

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
  String chatRetryStatus(String attempt, String seconds) {
    return 'Network hiccup — retrying ($attempt/∞) in ${seconds}s';
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

  @override
  String get settingsTabTimers => 'Timers';

  @override
  String get timerListEmpty =>
      'No timers set.\nThe AI can use the \"timer\" tool to schedule a reminder that comes back to itself.';

  @override
  String get timerListEmptyFilter => 'No timers match the filter.';

  @override
  String get timerAddTitle => 'Add timer';

  @override
  String get timerEditTitle => 'Edit timer';

  @override
  String get timerFieldLabel => 'Label';

  @override
  String get timerFieldLabelHint => 'e.g. Drink water';

  @override
  String get timerFieldLabelRequired => 'Please enter a label';

  @override
  String get timerFieldDelay => 'Delay (seconds)';

  @override
  String get timerFieldDelayHint => 'e.g. 300 = 5 minutes';

  @override
  String get timerFieldDelayInvalid => 'Delay must be a non-negative integer';

  @override
  String get timerFieldPrompt => 'Reminder body';

  @override
  String get timerFieldPromptHint =>
      'Optional. Becomes the notification body and is fed back to the AI when the timer fires.';

  @override
  String get timerFieldActionHint => 'AI hint';

  @override
  String get timerFieldActionHintHint =>
      'Optional. Tells the AI what to do when the timer fires (e.g. \"Call the notification tool\").';

  @override
  String get timerFieldFireAt => 'Fire at (ISO 8601)';

  @override
  String get timerFieldFireAtHint =>
      'Optional. Absolute time to fire (overrides delay).';

  @override
  String get timerStatusPending => 'Pending';

  @override
  String get timerStatusFired => 'Fired';

  @override
  String get timerStatusCancelled => 'Cancelled';

  @override
  String get timerActionEdit => 'Edit';

  @override
  String get timerActionCancel => 'Cancel';

  @override
  String get timerActionDelete => 'Delete';

  @override
  String get timerActionRestore => 'Re-activate';

  @override
  String get timerCancelConfirmTitle => 'Cancel timer?';

  @override
  String timerCancelConfirmMessage(Object label) {
    return 'The pending timer \"$label\" will be cancelled and won\'t fire.';
  }

  @override
  String get timerDeleteConfirmTitle => 'Delete timer?';

  @override
  String get timerDeleteConfirmMessage =>
      'The timer record will be removed from the list. This action cannot be undone.';

  @override
  String get timerShowAll => 'Show all (including fired / cancelled)';

  @override
  String get timerHideTerminal => 'Hide fired / cancelled';

  @override
  String timerFiresIn(String duration) {
    return 'Fires in $duration';
  }

  @override
  String timerFiredAt(String when) {
    return 'Fired at $when';
  }

  @override
  String get timerSourceAi => 'AI';

  @override
  String get timerSourceUser => 'User';

  @override
  String get timerNoteRuntime =>
      'Timers only fire while the app is running. Background / killed apps will not see the reminder.';

  @override
  String foregroundTimerTitleOne(String label) {
    return '1 active timer: $label';
  }

  @override
  String foregroundTimerTitleMany(int count) {
    return '$count active timers';
  }

  @override
  String get mcpListEmpty =>
      'No MCP servers added yet.\nTap \"Add\" in the bottom right to add an MCP server.';

  @override
  String get mcpAddTitle => 'Add MCP';

  @override
  String get mcpEditTitle => 'Edit MCP';

  @override
  String get mcpName => 'Name';

  @override
  String get mcpNameHint => 'e.g. Filesystem server';

  @override
  String get mcpNameRequired => 'Please enter an MCP name';

  @override
  String get mcpJsonConfig => 'MCP Config (JSON)';

  @override
  String get mcpJsonConfigHint =>
      'Paste MCP server config. HTTP: JSON with url/headers fields, or a plain URL. Stdio: JSON with command/args/env. Supports mcpServers wrapper.';

  @override
  String get mcpJsonConfigRequired => 'Please enter MCP config';

  @override
  String get mcpDeleteTitle => 'Delete MCP';

  @override
  String mcpDeleteConfirm(Object name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get mcpTestConnection => 'Test connection';

  @override
  String get mcpTesting => 'Testing…';

  @override
  String get mcpTestSuccess => 'Connected successfully';

  @override
  String get mcpTestFailed => 'Connection failed';

  @override
  String get googleSheetSheetTitle => 'Google Sheet';

  @override
  String get googleSheetSheetSubtitle =>
      'Connect Agent Buddy to a Google Sheet via OAuth. The model will be able to read / write the cells of the spreadsheet you choose.';

  @override
  String get googleSheetInputLabel => 'Spreadsheet URL or ID';

  @override
  String get googleSheetInputHint =>
      'https://docs.google.com/spreadsheets/d/…/edit   or   the bare ID';

  @override
  String get googleSheetTestButton => 'Test connection';

  @override
  String get googleSheetTestAuthorizing => 'Authorizing in browser…';

  @override
  String get googleSheetDefaultTabLabel =>
      'Default tab (used when the model omits `tab`)';

  @override
  String get googleSheetRefreshButton => 'Refresh tabs';

  @override
  String get googleSheetEmptyTabs =>
      'Click refresh to load tabs from the spreadsheet.';

  @override
  String get googleSheetEmptyTabsUnauthorized =>
      'Authorize first to load the tab list.';

  @override
  String get googleSheetSignOut => 'Sign out';

  @override
  String get googleSheetStatusUnconfigured => 'Not configured';

  @override
  String get googleSheetStatusUnauthorized =>
      'Not authorized — click Test connection';

  @override
  String get googleSheetStatusAuthorizing => 'Waiting for browser…';

  @override
  String get googleSheetStatusAuthorized => 'Connected';

  @override
  String googleSheetStatusAuthorizedAs(String email) {
    return 'Connected as $email';
  }

  @override
  String get googleSheetStatusError => 'Authorization error';
}
