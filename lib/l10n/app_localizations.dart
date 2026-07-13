import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent Buddy'**
  String get appTitle;

  /// No description provided for @commonAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// No description provided for @commonInUse.
  ///
  /// In en, this message translates to:
  /// **'In use'**
  String get commonInUse;

  /// No description provided for @commonError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get commonError;

  /// No description provided for @commonConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get commonConfirm;

  /// No description provided for @homeSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get homeSettingsTooltip;

  /// No description provided for @homeClearChatTooltip.
  ///
  /// In en, this message translates to:
  /// **'Clear chat'**
  String get homeClearChatTooltip;

  /// No description provided for @homeClearChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear chat'**
  String get homeClearChatTitle;

  /// No description provided for @homeClearChatMessage.
  ///
  /// In en, this message translates to:
  /// **'Clear all messages? This action cannot be undone.'**
  String get homeClearChatMessage;

  /// No description provided for @homeClearChatConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get homeClearChatConfirm;

  /// No description provided for @homeEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent Buddy'**
  String get homeEmptyTitle;

  /// No description provided for @homeEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap the settings button in the top left to add a model provider and a role to start chatting.'**
  String get homeEmptySubtitle;

  /// No description provided for @homeSessionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get homeSessionsTooltip;

  /// No description provided for @sessionManagerTitle.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get sessionManagerTitle;

  /// No description provided for @sessionManagerNew.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get sessionManagerNew;

  /// No description provided for @sessionManagerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No saved sessions yet.'**
  String get sessionManagerEmpty;

  /// No description provided for @sessionManagerSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get sessionManagerSelectAll;

  /// No description provided for @sessionManagerDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get sessionManagerDeselectAll;

  /// No description provided for @sessionManagerDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sessionManagerDelete;

  /// No description provided for @sessionManagerDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete session?'**
  String get sessionManagerDeleteConfirmTitle;

  /// No description provided for @sessionManagerDeleteBatchConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} sessions?'**
  String sessionManagerDeleteBatchConfirmTitle(int count);

  /// No description provided for @sessionManagerDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'The selected conversations will be removed. This action cannot be undone.'**
  String get sessionManagerDeleteMessage;

  /// No description provided for @homeNoModel.
  ///
  /// In en, this message translates to:
  /// **'No model configured'**
  String get homeNoModel;

  /// No description provided for @homeNoModelSelected.
  ///
  /// In en, this message translates to:
  /// **'No model selected'**
  String get homeNoModelSelected;

  /// No description provided for @homeProviderModel.
  ///
  /// In en, this message translates to:
  /// **'{provider} · {model}'**
  String homeProviderModel(String provider, String model);

  /// No description provided for @homeCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get homeCopied;

  /// No description provided for @homeLocalModelLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading model…'**
  String get homeLocalModelLoading;

  /// No description provided for @homeLocalModelReady.
  ///
  /// In en, this message translates to:
  /// **'Model loaded'**
  String get homeLocalModelReady;

  /// No description provided for @homeLocalModelRelease.
  ///
  /// In en, this message translates to:
  /// **'Release model'**
  String get homeLocalModelRelease;

  /// No description provided for @homeLocalModelReleaseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Free the local model from memory'**
  String get homeLocalModelReleaseTooltip;

  /// No description provided for @homeLocalModelReleased.
  ///
  /// In en, this message translates to:
  /// **'Model released'**
  String get homeLocalModelReleased;

  /// No description provided for @homeLocalModelLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load model: {error}'**
  String homeLocalModelLoadFailed(String error);

  /// No description provided for @homeLocalModelRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get homeLocalModelRetry;

  /// No description provided for @homeLocalModelDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get homeLocalModelDismiss;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsTabGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsTabGeneral;

  /// No description provided for @settingsTabProvider.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get settingsTabProvider;

  /// No description provided for @settingsTabRole.
  ///
  /// In en, this message translates to:
  /// **'Role'**
  String get settingsTabRole;

  /// No description provided for @settingsTabTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get settingsTabTools;

  /// No description provided for @settingsTabSkill.
  ///
  /// In en, this message translates to:
  /// **'Skill'**
  String get settingsTabSkill;

  /// No description provided for @settingsTabMcp.
  ///
  /// In en, this message translates to:
  /// **'MCP'**
  String get settingsTabMcp;

  /// No description provided for @settingsTabMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get settingsTabMemory;

  /// No description provided for @providerListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No model providers added yet.\nTap \"Add\" in the bottom right to start.'**
  String get providerListEmpty;

  /// No description provided for @providerAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Provider'**
  String get providerAddTitle;

  /// No description provided for @providerEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Provider'**
  String get providerEditTitle;

  /// No description provided for @providerProtocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get providerProtocol;

  /// No description provided for @providerProtocolOpenAI.
  ///
  /// In en, this message translates to:
  /// **'OpenAI'**
  String get providerProtocolOpenAI;

  /// No description provided for @providerProtocolAnthropic.
  ///
  /// In en, this message translates to:
  /// **'Anthropic'**
  String get providerProtocolAnthropic;

  /// No description provided for @providerName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get providerName;

  /// No description provided for @providerNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. OpenAI Official'**
  String get providerNameHint;

  /// No description provided for @providerNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a name'**
  String get providerNameRequired;

  /// No description provided for @providerBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get providerBaseUrl;

  /// No description provided for @providerBaseUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://api.openai.com'**
  String get providerBaseUrlHint;

  /// No description provided for @providerBaseUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a Base URL'**
  String get providerBaseUrlRequired;

  /// No description provided for @providerApiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get providerApiKey;

  /// No description provided for @providerApiKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter an API Key'**
  String get providerApiKeyRequired;

  /// No description provided for @providerChatPath.
  ///
  /// In en, this message translates to:
  /// **'Chat Path'**
  String get providerChatPath;

  /// No description provided for @providerChatPathHelper.
  ///
  /// In en, this message translates to:
  /// **'Auto-filled based on protocol, usually no need to modify'**
  String get providerChatPathHelper;

  /// No description provided for @providerChatPathRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a Chat Path'**
  String get providerChatPathRequired;

  /// No description provided for @providerTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get providerTestConnection;

  /// No description provided for @providerFetchModels.
  ///
  /// In en, this message translates to:
  /// **'Fetch models'**
  String get providerFetchModels;

  /// No description provided for @providerSelectModel.
  ///
  /// In en, this message translates to:
  /// **'Select default model'**
  String get providerSelectModel;

  /// No description provided for @providerTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing connection…'**
  String get providerTesting;

  /// No description provided for @providerTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connected successfully'**
  String get providerTestSuccess;

  /// No description provided for @providerTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed, please check URL/API Key'**
  String get providerTestFailed;

  /// No description provided for @providerFetching.
  ///
  /// In en, this message translates to:
  /// **'Fetching model list…'**
  String get providerFetching;

  /// No description provided for @providerFetchSuccess.
  ///
  /// In en, this message translates to:
  /// **'Fetched {count} models'**
  String providerFetchSuccess(int count);

  /// No description provided for @providerFetchFailed.
  ///
  /// In en, this message translates to:
  /// **'Fetch failed: {error}'**
  String providerFetchFailed(String error);

  /// No description provided for @providerModelCount.
  ///
  /// In en, this message translates to:
  /// **'{count} models'**
  String providerModelCount(int count);

  /// No description provided for @providerCurrentModel.
  ///
  /// In en, this message translates to:
  /// **'Current model: {model}'**
  String providerCurrentModel(String model);

  /// No description provided for @providerSetAsDefault.
  ///
  /// In en, this message translates to:
  /// **'Set as default'**
  String get providerSetAsDefault;

  /// No description provided for @providerTest.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get providerTest;

  /// No description provided for @providerDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Provider'**
  String get providerDeleteTitle;

  /// No description provided for @providerDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String providerDeleteConfirm(String name);

  /// No description provided for @settingsTabLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get settingsTabLocal;

  /// No description provided for @providerUseLocalModel.
  ///
  /// In en, this message translates to:
  /// **'Use a local model instead'**
  String get providerUseLocalModel;

  /// No description provided for @localProviderListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No local models added yet.\nTap \"Add\" in the bottom right to load a GGUF model from disk.'**
  String get localProviderListEmpty;

  /// No description provided for @localProviderAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Local Model'**
  String get localProviderAddTitle;

  /// No description provided for @localProviderEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Local Model'**
  String get localProviderEditTitle;

  /// No description provided for @localProviderName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get localProviderName;

  /// No description provided for @localProviderNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Qwen2.5 7B (Local)'**
  String get localProviderNameHint;

  /// No description provided for @localProviderNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a display name'**
  String get localProviderNameRequired;

  /// No description provided for @localProviderModelFile.
  ///
  /// In en, this message translates to:
  /// **'Model file (.gguf)'**
  String get localProviderModelFile;

  /// No description provided for @localProviderModelFileRequired.
  ///
  /// In en, this message translates to:
  /// **'Please pick a model file'**
  String get localProviderModelFileRequired;

  /// No description provided for @localProviderPickModelFile.
  ///
  /// In en, this message translates to:
  /// **'Pick model file'**
  String get localProviderPickModelFile;

  /// No description provided for @localProviderMmprojFile.
  ///
  /// In en, this message translates to:
  /// **'Multimodal projector (mmproj, optional)'**
  String get localProviderMmprojFile;

  /// No description provided for @localProviderPickMmproj.
  ///
  /// In en, this message translates to:
  /// **'Pick mmproj file'**
  String get localProviderPickMmproj;

  /// No description provided for @localProviderMmprojHint.
  ///
  /// In en, this message translates to:
  /// **'If the model is multimodal, pick a matching mmproj-*.gguf from the same directory.'**
  String get localProviderMmprojHint;

  /// No description provided for @localProviderAutoDetectMmproj.
  ///
  /// In en, this message translates to:
  /// **'Auto-detect from same directory'**
  String get localProviderAutoDetectMmproj;

  /// No description provided for @localProviderContextSize.
  ///
  /// In en, this message translates to:
  /// **'Context size'**
  String get localProviderContextSize;

  /// No description provided for @localProviderTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get localProviderTemperature;

  /// No description provided for @localProviderGpuLayers.
  ///
  /// In en, this message translates to:
  /// **'GPU layers'**
  String get localProviderGpuLayers;

  /// No description provided for @localProviderGpuLayersHint.
  ///
  /// In en, this message translates to:
  /// **'0 = CPU only. Higher values offload more layers to GPU.'**
  String get localProviderGpuLayersHint;

  /// No description provided for @localProviderMaxTokens.
  ///
  /// In en, this message translates to:
  /// **'Max generated tokens'**
  String get localProviderMaxTokens;

  /// No description provided for @localProviderKvCacheK.
  ///
  /// In en, this message translates to:
  /// **'KV cache (K) quantization'**
  String get localProviderKvCacheK;

  /// No description provided for @localProviderKvCacheV.
  ///
  /// In en, this message translates to:
  /// **'KV cache (V) quantization'**
  String get localProviderKvCacheV;

  /// No description provided for @localProviderKvCacheHint.
  ///
  /// In en, this message translates to:
  /// **'f16 = full quality, q8_0 ≈ 0.5× memory, q4_0 ≈ 0.25×. Non-f16 requires flash attention.'**
  String get localProviderKvCacheHint;

  /// No description provided for @localProviderBatchSize.
  ///
  /// In en, this message translates to:
  /// **'Batch size (n_batch)'**
  String get localProviderBatchSize;

  /// No description provided for @localProviderBatchSizeHint.
  ///
  /// In en, this message translates to:
  /// **'Per-step compute buffer. Default 512 (matches LM Studio / Ollama). Raising it speeds up prefill of long prompts but uses more memory.'**
  String get localProviderBatchSizeHint;

  /// No description provided for @localProviderMemTitle.
  ///
  /// In en, this message translates to:
  /// **'Memory estimate'**
  String get localProviderMemTitle;

  /// No description provided for @localProviderMemModel.
  ///
  /// In en, this message translates to:
  /// **'Model weights'**
  String get localProviderMemModel;

  /// No description provided for @localProviderMemKv.
  ///
  /// In en, this message translates to:
  /// **'KV cache'**
  String get localProviderMemKv;

  /// No description provided for @localProviderMemCompute.
  ///
  /// In en, this message translates to:
  /// **'Compute buffer'**
  String get localProviderMemCompute;

  /// No description provided for @localProviderMemTotal.
  ///
  /// In en, this message translates to:
  /// **'Estimated total'**
  String get localProviderMemTotal;

  /// No description provided for @localProviderMemMissing.
  ///
  /// In en, this message translates to:
  /// **'Pick a model file to see the memory estimate.'**
  String get localProviderMemMissing;

  /// No description provided for @localProviderMemLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading GGUF header...'**
  String get localProviderMemLoading;

  /// No description provided for @localProviderSetAsDefault.
  ///
  /// In en, this message translates to:
  /// **'Set as default'**
  String get localProviderSetAsDefault;

  /// No description provided for @localProviderDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Local Model'**
  String get localProviderDeleteTitle;

  /// No description provided for @localProviderDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String localProviderDeleteConfirm(String name);

  /// No description provided for @localProviderParams.
  ///
  /// In en, this message translates to:
  /// **'Parameters'**
  String get localProviderParams;

  /// No description provided for @localProviderFileMissing.
  ///
  /// In en, this message translates to:
  /// **'File not found: {path}'**
  String localProviderFileMissing(String path);

  /// No description provided for @localProviderMmprojDetected.
  ///
  /// In en, this message translates to:
  /// **'Detected: {name}'**
  String localProviderMmprojDetected(String name);

  /// No description provided for @localProviderClearMmproj.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get localProviderClearMmproj;

  /// No description provided for @roleListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No roles added yet.\nTap \"Add\" in the bottom right to create your first role.'**
  String get roleListEmpty;

  /// No description provided for @roleAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Role'**
  String get roleAddTitle;

  /// No description provided for @roleEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Role'**
  String get roleEditTitle;

  /// No description provided for @roleName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get roleName;

  /// No description provided for @roleNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Translation assistant'**
  String get roleNameHint;

  /// No description provided for @roleNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a role name'**
  String get roleNameRequired;

  /// No description provided for @roleDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get roleDescription;

  /// No description provided for @roleDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'A short description of what this role does'**
  String get roleDescriptionHint;

  /// No description provided for @roleSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'System Prompt'**
  String get roleSystemPrompt;

  /// No description provided for @roleSystemPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Describe the role\'s identity, behavior, style and rules'**
  String get roleSystemPromptHint;

  /// No description provided for @roleUseRole.
  ///
  /// In en, this message translates to:
  /// **'Use this role'**
  String get roleUseRole;

  /// No description provided for @roleUnuseRole.
  ///
  /// In en, this message translates to:
  /// **'Stop using'**
  String get roleUnuseRole;

  /// No description provided for @roleDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Role'**
  String get roleDeleteTitle;

  /// No description provided for @roleDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String roleDeleteConfirm(String name);

  /// No description provided for @toolsListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No built-in tools'**
  String get toolsListEmpty;

  /// No description provided for @toolsMasterSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Use Tools'**
  String get toolsMasterSwitchTitle;

  /// No description provided for @toolsMasterSwitchDescription.
  ///
  /// In en, this message translates to:
  /// **'Master switch for all built-in tools. Turn off for a pure chat experience to save tokens — the model won\'t see or call any tool until you turn this back on. Individual tool settings below are preserved.'**
  String get toolsMasterSwitchDescription;

  /// No description provided for @toolsMasterOffHint.
  ///
  /// In en, this message translates to:
  /// **'All tools are off. The model will reply in plain text only.'**
  String get toolsMasterOffHint;

  /// No description provided for @downloadStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting…'**
  String get downloadStatusPending;

  /// No description provided for @downloadStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloadStatusRunning;

  /// No description provided for @downloadStatusCompleted.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get downloadStatusCompleted;

  /// No description provided for @downloadStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get downloadStatusFailed;

  /// No description provided for @downloadStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get downloadStatusCancelled;

  /// No description provided for @downloadStatusSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get downloadStatusSaved;

  /// No description provided for @downloadProgressIndeterminate.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloadProgressIndeterminate;

  /// No description provided for @downloadActionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get downloadActionSave;

  /// No description provided for @downloadActionReveal.
  ///
  /// In en, this message translates to:
  /// **'Open folder'**
  String get downloadActionReveal;

  /// No description provided for @downloadActionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get downloadActionCancel;

  /// No description provided for @downloadActionDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get downloadActionDiscard;

  /// No description provided for @downloadPickFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a folder to save the file in'**
  String get downloadPickFolderTitle;

  /// No description provided for @downloadSavedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String downloadSavedSnackbar(String path);

  /// No description provided for @downloadSaveFailedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String downloadSaveFailedSnackbar(String error);

  /// No description provided for @downloadDiscardedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Discarded'**
  String get downloadDiscardedSnackbar;

  /// No description provided for @downloadExpiredHint.
  ///
  /// In en, this message translates to:
  /// **'This file is no longer in the app\'s temp directory. Ask the AI to re-download.'**
  String get downloadExpiredHint;

  /// No description provided for @remindersPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a todo calendar'**
  String get remindersPickerTitle;

  /// No description provided for @remindersPickerDescription.
  ///
  /// In en, this message translates to:
  /// **'Android stores reminders as all-day events in one of your calendars. Pick the calendar Agent Buddy should use to save your reminders and to-dos.'**
  String get remindersPickerDescription;

  /// No description provided for @remindersPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No writable calendar found. Add a local or Google calendar on this device first, then come back.'**
  String get remindersPickerEmpty;

  /// No description provided for @skillListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No skills added yet.\nSkills provide extra instructions to the AI during chat.\nTap \"Add\" in the bottom right to start.'**
  String get skillListEmpty;

  /// No description provided for @skillAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Skill'**
  String get skillAddTitle;

  /// No description provided for @skillEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Skill'**
  String get skillEditTitle;

  /// No description provided for @skillName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get skillName;

  /// No description provided for @skillNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Code review'**
  String get skillNameHint;

  /// No description provided for @skillNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a skill name'**
  String get skillNameRequired;

  /// No description provided for @skillDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get skillDescription;

  /// No description provided for @skillDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'A short description of what this skill does'**
  String get skillDescriptionHint;

  /// No description provided for @skillContent.
  ///
  /// In en, this message translates to:
  /// **'Content (Markdown)'**
  String get skillContent;

  /// No description provided for @skillContentHint.
  ///
  /// In en, this message translates to:
  /// **'Skill content in Markdown format'**
  String get skillContentHint;

  /// No description provided for @skillDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Skill'**
  String get skillDeleteTitle;

  /// No description provided for @skillDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String skillDeleteConfirm(String name);

  /// No description provided for @chatInputHint.
  ///
  /// In en, this message translates to:
  /// **'Say something…'**
  String get chatInputHint;

  /// No description provided for @chatInputHintNoModel.
  ///
  /// In en, this message translates to:
  /// **'Please add a model in settings first'**
  String get chatInputHintNoModel;

  /// No description provided for @chatInputHintReplying.
  ///
  /// In en, this message translates to:
  /// **'Model is replying…'**
  String get chatInputHintReplying;

  /// No description provided for @imageAttachTooltip.
  ///
  /// In en, this message translates to:
  /// **'Attach image'**
  String get imageAttachTooltip;

  /// No description provided for @imagePickGallery.
  ///
  /// In en, this message translates to:
  /// **'Choose from gallery'**
  String get imagePickGallery;

  /// No description provided for @imagePickCamera.
  ///
  /// In en, this message translates to:
  /// **'Take a photo'**
  String get imagePickCamera;

  /// No description provided for @imageRemoveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove image'**
  String get imageRemoveTooltip;

  /// No description provided for @imageErrorFailedToAttach.
  ///
  /// In en, this message translates to:
  /// **'Failed to attach image: {error}'**
  String imageErrorFailedToAttach(String error);

  /// No description provided for @messageThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get messageThinking;

  /// No description provided for @messageErrorPrefix.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String messageErrorPrefix(String error);

  /// No description provided for @codeCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get codeCopy;

  /// No description provided for @codeCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get codeCopied;

  /// No description provided for @imageLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load image'**
  String get imageLoadFailed;

  /// No description provided for @toolCallArguments.
  ///
  /// In en, this message translates to:
  /// **'Arguments'**
  String get toolCallArguments;

  /// No description provided for @toolCallResult.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get toolCallResult;

  /// No description provided for @toolCallStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get toolCallStatusPending;

  /// No description provided for @toolCallStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get toolCallStatusRunning;

  /// No description provided for @toolCallStatusSuccess.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get toolCallStatusSuccess;

  /// No description provided for @toolCallStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get toolCallStatusFailed;

  /// No description provided for @toolCallDurationMs.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms'**
  String toolCallDurationMs(int ms);

  /// No description provided for @toolCallDurationSec.
  ///
  /// In en, this message translates to:
  /// **'{sec}s'**
  String toolCallDurationSec(String sec);

  /// No description provided for @toolCallNoArguments.
  ///
  /// In en, this message translates to:
  /// **'(no arguments)'**
  String get toolCallNoArguments;

  /// No description provided for @toolCallNoResult.
  ///
  /// In en, this message translates to:
  /// **'(no result)'**
  String get toolCallNoResult;

  /// No description provided for @toolCallExpand.
  ///
  /// In en, this message translates to:
  /// **'Show details'**
  String get toolCallExpand;

  /// No description provided for @toolCallCollapse.
  ///
  /// In en, this message translates to:
  /// **'Hide details'**
  String get toolCallCollapse;

  /// No description provided for @toolCallRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get toolCallRetry;

  /// No description provided for @toolCallRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry this tool call'**
  String get toolCallRetryFailed;

  /// No description provided for @toolGroupSummary.
  ///
  /// In en, this message translates to:
  /// **'{count} tool calls'**
  String toolGroupSummary(int count);

  /// No description provided for @toolCallRetryNote.
  ///
  /// In en, this message translates to:
  /// **'[Retry of {tool}] The tool returned the following new result. Please use it to continue or correct your previous answer:\n\n{result}'**
  String toolCallRetryNote(String tool, String result);

  /// No description provided for @chatNoProvider.
  ///
  /// In en, this message translates to:
  /// **'Please add and enable a model provider in settings first.'**
  String get chatNoProvider;

  /// No description provided for @chatNoModel.
  ///
  /// In en, this message translates to:
  /// **'No model is available for the current provider. Please fetch and select a model in settings.'**
  String get chatNoModel;

  /// No description provided for @chatRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'Request failed: {error}'**
  String chatRequestFailed(String error);

  /// No description provided for @generalSectionAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get generalSectionAppearance;

  /// No description provided for @generalDarkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark mode'**
  String get generalDarkMode;

  /// No description provided for @generalThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get generalThemeSystem;

  /// No description provided for @generalThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get generalThemeLight;

  /// No description provided for @generalThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get generalThemeDark;

  /// No description provided for @generalSectionLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get generalSectionLanguage;

  /// No description provided for @generalLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get generalLanguageSystem;

  /// No description provided for @generalLanguageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get generalLanguageEn;

  /// No description provided for @generalLanguageZh.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get generalLanguageZh;

  /// No description provided for @generalSectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get generalSectionAbout;

  /// No description provided for @generalAboutAppName.
  ///
  /// In en, this message translates to:
  /// **'Agent Buddy'**
  String get generalAboutAppName;

  /// No description provided for @generalAboutTagline.
  ///
  /// In en, this message translates to:
  /// **'Cross-platform agent hub'**
  String get generalAboutTagline;

  /// No description provided for @generalAboutVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String generalAboutVersion(String version);

  /// No description provided for @memoryListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No memories yet.\nThe AI will write useful information here as you chat.'**
  String get memoryListEmpty;

  /// No description provided for @memorySearchEmpty.
  ///
  /// In en, this message translates to:
  /// **'No memories match \"{keyword}\".'**
  String memorySearchEmpty(String keyword);

  /// No description provided for @memoryAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Memory'**
  String get memoryAddTitle;

  /// No description provided for @memoryEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Memory'**
  String get memoryEditTitle;

  /// No description provided for @memoryContent.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get memoryContent;

  /// No description provided for @memoryContentHint.
  ///
  /// In en, this message translates to:
  /// **'A short, self-contained fact that will be remembered across sessions.'**
  String get memoryContentHint;

  /// No description provided for @memoryContentRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter the content'**
  String get memoryContentRequired;

  /// No description provided for @memorySourceAi.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get memorySourceAi;

  /// No description provided for @memorySourceUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get memorySourceUser;

  /// No description provided for @memoryDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Memory'**
  String get memoryDeleteTitle;

  /// No description provided for @memoryDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this memory?'**
  String get memoryDeleteConfirm;

  /// No description provided for @memoryDeleteBatchConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} memories?'**
  String memoryDeleteBatchConfirmTitle(int count);

  /// No description provided for @memoryDeleteBatchMessage.
  ///
  /// In en, this message translates to:
  /// **'The selected memories will be removed. This action cannot be undone.'**
  String get memoryDeleteBatchMessage;

  /// No description provided for @memorySearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get memorySearch;

  /// No description provided for @memorySearchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get memorySearchClear;

  /// No description provided for @memorySelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get memorySelectAll;

  /// No description provided for @memoryDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get memoryDeselectAll;

  /// No description provided for @memoryEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get memoryEdit;

  /// No description provided for @memoryJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get memoryJustNow;

  /// No description provided for @memoryMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} min ago'**
  String memoryMinutesAgo(int n);

  /// No description provided for @memoryHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} h ago'**
  String memoryHoursAgo(int n);

  /// No description provided for @memoryDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} d ago'**
  String memoryDaysAgo(int n);

  /// No description provided for @locationPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Location permission denied. Please grant it in system settings.'**
  String get locationPermissionDenied;

  /// No description provided for @locationPermanentlyDenied.
  ///
  /// In en, this message translates to:
  /// **'Location permission permanently denied. Open system settings to enable it.'**
  String get locationPermanentlyDenied;

  /// No description provided for @locationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Location unavailable. Make sure location services are on and try again.'**
  String get locationUnavailable;

  /// No description provided for @locationTimeout.
  ///
  /// In en, this message translates to:
  /// **'Location request timed out. Please try again.'**
  String get locationTimeout;

  /// No description provided for @settingsTabTimers.
  ///
  /// In en, this message translates to:
  /// **'Timers'**
  String get settingsTabTimers;

  /// No description provided for @timerListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No timers set.\nThe AI can use the \"timer\" tool to schedule a reminder that comes back to itself.'**
  String get timerListEmpty;

  /// No description provided for @timerListEmptyFilter.
  ///
  /// In en, this message translates to:
  /// **'No timers match the filter.'**
  String get timerListEmptyFilter;

  /// No description provided for @timerAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add timer'**
  String get timerAddTitle;

  /// No description provided for @timerEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit timer'**
  String get timerEditTitle;

  /// No description provided for @timerFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get timerFieldLabel;

  /// No description provided for @timerFieldLabelHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Drink water'**
  String get timerFieldLabelHint;

  /// No description provided for @timerFieldLabelRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a label'**
  String get timerFieldLabelRequired;

  /// No description provided for @timerFieldDelay.
  ///
  /// In en, this message translates to:
  /// **'Delay (seconds)'**
  String get timerFieldDelay;

  /// No description provided for @timerFieldDelayHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. 300 = 5 minutes'**
  String get timerFieldDelayHint;

  /// No description provided for @timerFieldDelayInvalid.
  ///
  /// In en, this message translates to:
  /// **'Delay must be a non-negative integer'**
  String get timerFieldDelayInvalid;

  /// No description provided for @timerFieldPrompt.
  ///
  /// In en, this message translates to:
  /// **'Reminder body'**
  String get timerFieldPrompt;

  /// No description provided for @timerFieldPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Optional. Becomes the notification body and is fed back to the AI when the timer fires.'**
  String get timerFieldPromptHint;

  /// No description provided for @timerFieldActionHint.
  ///
  /// In en, this message translates to:
  /// **'AI hint'**
  String get timerFieldActionHint;

  /// No description provided for @timerFieldActionHintHint.
  ///
  /// In en, this message translates to:
  /// **'Optional. Tells the AI what to do when the timer fires (e.g. \"Call the notification tool\").'**
  String get timerFieldActionHintHint;

  /// No description provided for @timerFieldFireAt.
  ///
  /// In en, this message translates to:
  /// **'Fire at (ISO 8601)'**
  String get timerFieldFireAt;

  /// No description provided for @timerFieldFireAtHint.
  ///
  /// In en, this message translates to:
  /// **'Optional. Absolute time to fire (overrides delay).'**
  String get timerFieldFireAtHint;

  /// No description provided for @timerStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get timerStatusPending;

  /// No description provided for @timerStatusFired.
  ///
  /// In en, this message translates to:
  /// **'Fired'**
  String get timerStatusFired;

  /// No description provided for @timerStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get timerStatusCancelled;

  /// No description provided for @timerActionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get timerActionEdit;

  /// No description provided for @timerActionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get timerActionCancel;

  /// No description provided for @timerActionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get timerActionDelete;

  /// No description provided for @timerActionRestore.
  ///
  /// In en, this message translates to:
  /// **'Re-activate'**
  String get timerActionRestore;

  /// No description provided for @timerCancelConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel timer?'**
  String get timerCancelConfirmTitle;

  /// No description provided for @timerCancelConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'The pending timer \"{label}\" will be cancelled and won\'t fire.'**
  String timerCancelConfirmMessage(Object label);

  /// No description provided for @timerDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete timer?'**
  String get timerDeleteConfirmTitle;

  /// No description provided for @timerDeleteConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'The timer record will be removed from the list. This action cannot be undone.'**
  String get timerDeleteConfirmMessage;

  /// No description provided for @timerShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show all (including fired / cancelled)'**
  String get timerShowAll;

  /// No description provided for @timerHideTerminal.
  ///
  /// In en, this message translates to:
  /// **'Hide fired / cancelled'**
  String get timerHideTerminal;

  /// No description provided for @timerFiresIn.
  ///
  /// In en, this message translates to:
  /// **'Fires in {duration}'**
  String timerFiresIn(String duration);

  /// No description provided for @timerFiredAt.
  ///
  /// In en, this message translates to:
  /// **'Fired at {when}'**
  String timerFiredAt(String when);

  /// No description provided for @timerSourceAi.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get timerSourceAi;

  /// No description provided for @timerSourceUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get timerSourceUser;

  /// No description provided for @timerNoteRuntime.
  ///
  /// In en, this message translates to:
  /// **'Timers only fire while the app is running. Background / killed apps will not see the reminder.'**
  String get timerNoteRuntime;

  /// No description provided for @foregroundTimerTitleOne.
  ///
  /// In en, this message translates to:
  /// **'1 active timer: {label}'**
  String foregroundTimerTitleOne(String label);

  /// No description provided for @foregroundTimerTitleMany.
  ///
  /// In en, this message translates to:
  /// **'{count} active timers'**
  String foregroundTimerTitleMany(int count);

  /// No description provided for @mcpListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No MCP servers added yet.\nTap \"Add\" in the bottom right to add an MCP server.'**
  String get mcpListEmpty;

  /// No description provided for @mcpAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add MCP'**
  String get mcpAddTitle;

  /// No description provided for @mcpEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit MCP'**
  String get mcpEditTitle;

  /// No description provided for @mcpName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get mcpName;

  /// No description provided for @mcpNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Filesystem server'**
  String get mcpNameHint;

  /// No description provided for @mcpNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter an MCP name'**
  String get mcpNameRequired;

  /// No description provided for @mcpJsonConfig.
  ///
  /// In en, this message translates to:
  /// **'MCP Config (JSON)'**
  String get mcpJsonConfig;

  /// No description provided for @mcpJsonConfigHint.
  ///
  /// In en, this message translates to:
  /// **'Paste MCP server config. HTTP: JSON with url/headers fields, or a plain URL. Stdio: JSON with command/args/env. Supports mcpServers wrapper.'**
  String get mcpJsonConfigHint;

  /// No description provided for @mcpJsonConfigRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter MCP config'**
  String get mcpJsonConfigRequired;

  /// No description provided for @mcpDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete MCP'**
  String get mcpDeleteTitle;

  /// No description provided for @mcpDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String mcpDeleteConfirm(Object name);

  /// No description provided for @mcpTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get mcpTestConnection;

  /// No description provided for @mcpTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get mcpTesting;

  /// No description provided for @mcpTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connected successfully'**
  String get mcpTestSuccess;

  /// No description provided for @mcpTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get mcpTestFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
