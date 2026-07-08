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
  String get settingsTitle => 'Settings';

  @override
  String get settingsTabProvider => 'Provider';

  @override
  String get settingsTabRole => 'Role';

  @override
  String get settingsTabTools => 'Tools';

  @override
  String get settingsTabSkill => 'Skill';

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
  String get chatNoProvider =>
      'Please add and enable a model provider in settings first.';

  @override
  String get chatNoModel =>
      'No model is available for the current provider. Please fetch and select a model in settings.';

  @override
  String chatRequestFailed(String error) {
    return 'Request failed: $error';
  }
}
