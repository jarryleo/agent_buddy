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

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsTabProvider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
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

  /// No description provided for @toolFetchWebName.
  ///
  /// In en, this message translates to:
  /// **'Fetch Web'**
  String get toolFetchWebName;

  /// No description provided for @toolFetchWebDescription.
  ///
  /// In en, this message translates to:
  /// **'Fetch the content of a URL and return the plain text of the page.'**
  String get toolFetchWebDescription;

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
