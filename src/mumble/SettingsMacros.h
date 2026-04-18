// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.


#ifndef MUMBLE_MUMBLE_SETTINGS_MACROS_H_
#define MUMBLE_MUMBLE_SETTINGS_MACROS_H_

#include "SettingsKeys.h"

// Mappings between SettingsKey objects and the corresponding fields in the Settings struct

#define MISC_SETTINGS                                                               \
	PROCESS(misc, DATABASE_LOCATION_KEY, qsDatabaseLocation)                        \
	PROCESS(misc, IMAGE_DIRECTORY_KEY, qsImagePath)                                 \
	PROCESS(misc, AUDIO_WIZARD_SHOWN_KEY, audioWizardShown)                         \
	PROCESS(misc, SERVER_PING_CONSENT_MESSAGE_VIEWED_KEY, bPingServersDialogViewed)

#define AUDIO_SETTINGS                                                                      \
	PROCESS(audio, UNMUTE_ON_UNDEAF_KEY, unmuteOnUndeaf)                                    \
	PROCESS(audio, MUTE_KEY, bMute)                                                         \
	PROCESS(audio, DEAF_KEY, bDeaf)                                                         \
	PROCESS(audio, TRANSMIT_MODE_KEY, atTransmit)                                           \
	PROCESS(audio, DOUBLE_PUSH_DELAY_KEY, uiDoublePush)                                     \
	PROCESS(audio, PTT_HOLD_KEY, pttHold)                                                   \
	PROCESS(audio, TRANSMIT_CUE_WHEN_PTT_KEY, audioCueEnabledPTT)                           \
	PROCESS(audio, TRANSMIT_CUE_WHEN_VAD_KEY, audioCueEnabledVAD)                           \
	PROCESS(audio, TRANSMIT_CUE_START_KEY, qsTxAudioCueOn)                                  \
	PROCESS(audio, TRANSMIT_CUE_STOP_KEY, qsTxAudioCueOff)                                  \
	PROCESS(audio, PLAY_MUTE_CUE_KEY, bTxMuteCue)                                           \
	PROCESS(audio, MUTE_CUE_KEY, qsTxMuteCue)                                               \
	PROCESS(audio, MUTE_CUE_POPUP_SHOWN, muteCueShown)                                      \
	PROCESS(audio, AUDIO_QUALITY_KEY, iQuality)                                             \
	PROCESS(audio, LOUDNESS_KEY, iMinLoudness)                                              \
	PROCESS(audio, VOLUME_KEY, fVolume)                                                     \
	PROCESS(audio, EXTERNAL_APPLICATIONS_VOLUME_KEY, fOtherVolume)                          \
	PROCESS(audio, LISTENER_ATTENUATION_FACTOR_KEY, listenerAttenuationFactor)              \
	PROCESS(audio, ALWAYS_ATTENUATE_LISTENERS_KEY, alwaysAttenuateListeners)                \
	PROCESS(audio, ATTENUATE_EXTERNAL_APPLICATIONS_KEY, bAttenuateOthers)                   \
	PROCESS(audio, ATTENUATE_EXTERNAL_APPLICATIONS_ON_TALK_KEY, bAttenuateOthersOnTalk)     \
	PROCESS(audio, ATTENUATE_USERS_ON_PRIORITY_SPEAKER_KEY, bAttenuateUsersOnPrioritySpeak) \
	PROCESS(audio, ATTENUATE_ONLY_SAME_OUTPUT_KEY, bOnlyAttenuateSameOutput)                \
	PROCESS(audio, ATTENUATE_LOOPBACK_KEY, bAttenuateLoopbacks)                             \
	PROCESS(audio, VAD_MODE_KEY, vsVAD)                                                     \
	PROCESS(audio, VAD_MIN_KEY, fVADmin)                                                    \
	PROCESS(audio, VAD_MAX_KEY, fVADmax)                                                    \
	PROCESS(audio, NOISE_CANCEL_MODE_KEY, noiseCancelMode)                                  \
	PROCESS(audio, SPEEX_NOISE_CANCEL_STRENGTH_KEY, iSpeexNoiseCancelStrength)              \
	PROCESS(audio, INPUT_CHANNEL_MASK_KEY, uiAudioInputChannelMask)                         \
	PROCESS(audio, ALLOW_LOW_DELAY_MODE_KEY, bAllowLowDelay)                                \
	PROCESS(audio, VOICE_HOLD_KEY, iVoiceHold)                                              \
	PROCESS(audio, OUTPUT_DELAY_KEY, iOutputDelay)                                          \
	PROCESS(audio, ECHO_CANCEL_MODE_KEY, echoOption)                                        \
	PROCESS(audio, EXCLUSIVE_INPUT_KEY, bExclusiveInput)                                    \
	PROCESS(audio, EXCLUSIVE_OUTPUT_KEY, bExclusiveOutput)                                  \
	PROCESS(audio, INPUT_SYSTEM_KEY, qsAudioInput)                                          \
	PROCESS(audio, OUTPUT_SYSTEM_KEY, qsAudioOutput)                                        \
	PROCESS(audio, NOTIFICATION_VOLUME_KEY, notificationVolume)                             \
	PROCESS(audio, CUE_VOLUME_KEY, cueVolume)                                               \
	PROCESS(audio, RESTRICT_WHISPERS_TO_FRIENDS_KEY, bWhisperFriends)                       \
	PROCESS(audio, NOTIFICATION_USER_LIMIT_KEY, iMessageLimitUserThreshold)


#define IDLE_SETTINGS                             \
	PROCESS(idle, IDLE_TIME_KEY, iIdleTime)       \
	PROCESS(idle, IDLE_ACTION_KEY, iaeIdleAction) \
	PROCESS(idle, UNDO_IDLE_ACTION_UPON_ACTIVITY, bUndoIdleActionUponActivity)


#define POSITIONAL_AUDIO_SETTINGS                                                  \
	PROCESS(positional_audio, ENABLE_POSITIONAL_AUDIO_KEY, bPositionalAudio)       \
	PROCESS(positional_audio, POSITIONAL_MIN_DISTANCE_KEY, fAudioMinDistance)      \
	PROCESS(positional_audio, POSITIONAL_MAX_DISTANCE_KEY, fAudioMaxDistance)      \
	PROCESS(positional_audio, POSITIONAL_MIN_VOLUME_KEY, fAudioMaxDistVolume)      \
	PROCESS(positional_audio, POSITIONAL_BLOOM_KEY, fAudioBloom)                   \
	PROCESS(positional_audio, POSITIONAL_HEADPHONE_MODE_KEY, bPositionalHeadphone) \
	PROCESS(positional_audio, POSITIONAL_TRANSMIT_POSITION_KEY, bTransmitPosition)


#define NETWORK_SETTINGS                                                     \
	PROCESS(network, JITTER_BUFFER_SIZE_KEY, iJitterBufferSize)              \
	PROCESS(network, FRAMES_PER_PACKET_KEY, iFramesPerPacket)                \
	PROCESS(network, RESTRICT_TO_TCP_KEY, bTCPCompat)                        \
	PROCESS(network, USE_QUALITY_OF_SERVICE_KEY, bQoS)                       \
	PROCESS(network, AUTO_RECONNECT_KEY, bReconnect)                         \
	PROCESS(network, AUTO_CONNECT_LAST_SERVER_KEY, bAutoConnect)             \
	PROCESS(network, PROXY_TYPE_KEY, ptProxyType)                            \
	PROCESS(network, PROXY_HOST_KEY, qsProxyHost)                            \
	PROCESS(network, PROXY_PORT_KEY, usProxyPort)                            \
	PROCESS(network, PROXY_USERNAME_KEY, qsProxyUsername)                    \
	PROCESS(network, PROXY_PASSWORD_KEY, qsProxyPassword)                    \
	PROCESS(network, MAX_IMAGE_WIDTH_KEY, iMaxImageWidth)                    \
	PROCESS(network, MAX_IMAGE_HEIGHT_KEY, iMaxImageHeight)                  \
	PROCESS(network, SERVICE_PREFIX_KEY, qsServicePrefix)                    \
	PROCESS(network, MAX_IN_FLIGHT_TCP_PINGS_KEY, iMaxInFlightTCPPings)      \
	PROCESS(network, PING_INTERVAL_KEY, iPingIntervalMsec)                   \
	PROCESS(network, CONNECTION_TIMEOUT_KEY, iConnectionTimeoutDurationMsec) \
	PROCESS(network, FORCE_UDP_BIND_TO_TCP_ADDRESS_KEY, bUdpForceTcpAddr)    \
	PROCESS(network, SSL_CIPHERS_KEY, qsSslCiphers)


#define AUDIO_BACKEND_SETTINGS                                      \
	PROCESS(audio_backend, COREAUDIO_INPUT_KEY, qsCoreAudioInput)   \
	PROCESS(audio_backend, COREAUDIO_OUTPUT_KEY, qsCoreAudioOutput)


#define TTS_SETTINGS                                    \
	PROCESS(tts, TTS_ENABLE_KEY, bTTS)                  \
	PROCESS(tts, TTS_VOLUME_KEY, iTTSVolume)            \
	PROCESS(tts, TTS_THRESHOLD_KEY, iTTSThreshold)      \
	PROCESS(tts, TTS_READBACK_KEY, bTTSMessageReadBack) \
	PROCESS(tts, TTS_IGNORE_SCOPE_KEY, bTTSNoScope)     \
	PROCESS(tts, TTS_IGNORE_AUTHOR_KEY, bTTSNoAuthor)   \
	PROCESS(tts, TTS_LANGAGE_KEY, qsTTSLanguage)


#define PRIVACY_SETTINGS PROCESS(privacy, HIDE_OS_FROM_SERVER_KEY, bHideOS)


#define UI_SETTINGS                                                              \
	PROCESS(ui, LANGUAGE_KEY, qsLanguage)                                        \
	PROCESS(ui, THEME_KEY, themeName)                                            \
	PROCESS(ui, THEME_STYLE_KEY, themeStyleName)                                 \
	PROCESS(ui, THEME_DARK_KEY, themeDarkName)                                   \
	PROCESS(ui, THEME_DARK_STYLE_KEY, themeDarkStyleName)                        \
	PROCESS(ui, THEME_METHOD_KEY, styleType)                                     \
	PROCESS(ui, CHANNEL_EXPANSION_MODE_KEY, ceExpand)                            \
	PROCESS(ui, CHANNEL_DRAG_MODE_KEY, ceChannelDrag)                            \
	PROCESS(ui, USER_DRAG_MODE_KEY, ceUserDrag)                                  \
	PROCESS(ui, ALWAYS_ON_TOP_KEY, aotbAlwaysOnTop)                              \
	PROCESS(ui, QUIT_BEHAVIOR_KEY, quitBehavior)                                 \
	PROCESS(ui, SHOW_DEVELOPER_MENU_KEY, bEnableDeveloperMenu)                   \
	PROCESS(ui, LOCK_LAYOUT_KEY, bLockLayout)                                    \
	PROCESS(ui, MINIMAL_VIEW_KEY, bMinimalView)                                  \
	PROCESS(ui, HIDE_FRAME_KEY, bHideFrame)                                      \
	PROCESS(ui, DISPLAY_USERS_BEFORE_CHANNELS, bUserTop)                         \
	PROCESS(ui, WINDOW_GEOMETRY_KEY, qbaMainWindowGeometry)                      \
	PROCESS(ui, WINDOW_GEOMETRY_MINIMAL_VIEW_KEY, qbaMinimalViewGeometry)        \
	PROCESS(ui, WINDOW_STATE_KEY, qbaMainWindowState)                            \
	PROCESS(ui, WINDOW_STATE_MINIMAL_VIEW_KEY, qbaMinimalViewState)              \
	PROCESS(ui, CONFIG_GEOMETRY_KEY, qbaConfigGeometry)                          \
	PROCESS(ui, WINDOW_LAYOUT_KEY, wlWindowLayout)                               \
	PROCESS(ui, SERVER_FILTER_MODE_KEY, ssFilter)                                \
	PROCESS(ui, HIDE_IN_TRAY_KEY, bHideInTray)                                   \
	PROCESS(ui, DISPLAY_TALKING_STATE_IN_TRAY_KEY, bStateInTray)                 \
	PROCESS(ui, DISPLAY_USER_COUNT_KEY, bShowUserCount)                          \
	PROCESS(ui, DISPLAY_VOLUME_ADJUSTMENTS_KEY, bShowVolumeAdjustments)          \
	PROCESS(ui, DISPLAY_NICKNAMES_ONLY_KEY, bShowNicknamesOnly)                  \
	PROCESS(ui, SELECTED_ITEM_AS_CHATBAR_TARGET_KEY, bChatBarUseSelection)       \
	PROCESS(ui, FILTER_HIDES_EMPTY_CHANNEL_KEY, bFilterHidesEmptyChannels)       \
	PROCESS(ui, FILTER_ACTIVE_KEY, bFilterActive)                                \
	PROCESS(ui, CONTEXT_MENU_ENTRIES_IN_MENU_BAR_KEY, bShowContextMenuInMenuBar) \
	PROCESS(ui, CONNECT_DIALOG_GEOMETRY_KEY, qbaConnectDialogGeometry)           \
	PROCESS(ui, CONNECT_DIALOG_HEADER_STATE_KEY, qbaConnectDialogHeader)         \
	PROCESS(ui, DISPLAY_TRANSMIT_MODE_COMBOBOX_KEY, bShowTransmitModeComboBox)   \
	PROCESS(ui, HIGH_CONTRAST_MODE_KEY, bHighContrast)                           \
	PROCESS(ui, MAX_LOG_LENGTH_KEY, iMaxLogBlocks)                               \
	PROCESS(ui, USE_24H_CLOCK_KEY, bLog24HourClock)                              \
	PROCESS(ui, LOG_MESSAGE_MARGINS_KEY, iChatMessageMargins)                    \
	PROCESS(ui, DISABLE_PUBLIC_SERVER_LIST_KEY, bDisablePublicList)


#define UPDATE_SETTINGS                                         \
	PROCESS(update, CHECK_FOR_PLUGIN_UPDATES_KEY, bPluginCheck) \
	PROCESS(update, AUTO_UPDATE_PLUGINS_KEY, bPluginAutoUpdate)


#define LAST_CONNECTION_SETTINGS                            \
	PROCESS(last_connection, LAST_USERNAME_KEY, qsUsername) \
	PROCESS(last_connection, LAST_SERVER_NAME_KEY, qsLastServer)


#define TALKINGUI_SETTINGS                                                                            \
	PROCESS(talkingui, TALKINGUI_POSITION_KEY, qpTalkingUI_Position)                                  \
	PROCESS(talkingui, SHOW_TALKINGUI_KEY, bShowTalkingUI)                                            \
	PROCESS(talkingui, TALKINGUI_USERS_ALWAYS_VISIBLE_KEY, talkingUI_UsersAlwaysVisible)              \
	PROCESS(talkingui, TALKINGUI_LOCAL_USER_STAYS_VISIBLE_KEY, bTalkingUI_LocalUserStaysVisible)      \
	PROCESS(talkingui, TALKINGUI_ABBREVIATE_CHANNEL_NAMES_KEY, bTalkingUI_AbbreviateChannelNames)     \
	PROCESS(talkingui, TALKINGUI_ABBREVIATE_CURRENT_CHANNEL_KEY, bTalkingUI_AbbreviateCurrentChannel) \
	PROCESS(talkingui, TALKINGUI_DISPLAY_LOCAL_LISTENERS_KEY, bTalkingUI_ShowLocalListeners)          \
	PROCESS(talkingui, TALKINGUI_RELATIVE_FONT_SIZE_KEY, iTalkingUI_RelativeFontSize)                 \
	PROCESS(talkingui, TALKINGUI_SILENT_USER_LIFETIME_KEY, iTalkingUI_SilentUserLifeTime)             \
	PROCESS(talkingui, TALKINGUI_CHANNEL_HIERARCHY_DEPTH_KEY, iTalkingUI_ChannelHierarchyDepth)       \
	PROCESS(talkingui, TALKINGUI_MAX_CHANNEL_NAME_LENGTH_KEY, iTalkingUI_MaxChannelNameLength)        \
	PROCESS(talkingui, TALKINGUI_NAME_PREFIX_COUNT_KEY, iTalkingUI_PrefixCharCount)                   \
	PROCESS(talkingui, TALKINGUI_NAME_POSTFIX_COUNT_KEY, iTalkingUI_PostfixCharCount)                 \
	PROCESS(talkingui, TALKINGUI_ABBREVIATION_REPLACEMENT_KEY, qsTalkingUI_AbbreviationReplacement)   \
	PROCESS(talkingui, TALKINGUI_BACKGROUND_COLOR_KEY, talkingUI_BackgroundColor)


#define CHANNEL_HIERARCHY_SETTINGS PROCESS(channel_hierarchy, CHANNEL_NAME_SEPARATOR_KEY, qsHierarchyChannelSeparator)


#define MANUAL_PLUGIN_SETTINGS \
	PROCESS(manual_plugin, MANUALPLUGIN_SILENT_USER_LIFETIME_KEY, manualPlugin_silentUserDisplaytime)


#define PTT_WINDOW_SETTINGS                                          \
	PROCESS(ptt_window, DISPLAY_PTTWINDOW_KEY, bShowPTTButtonWindow) \
	PROCESS(ptt_window, PTTWINDOW_GEOMETRY_KEY, qbaPTTButtonWindowGeometry)


#define RECORDING_SETTINGS                                  \
	PROCESS(recording, RECORDING_PATH_KEY, qsRecordingPath) \
	PROCESS(recording, RECORDING_FILE_KEY, qsRecordingFile) \
	PROCESS(recording, RECORDING_MODE_KEY, rmRecordingMode) \
	PROCESS(recording, RECORDING_FORMAT_KEY, iRecordingFormat)


#define HIDDEN_SETTINGS PROCESS(hidden, DISABLE_CONNECT_DIALOG_EDITING_KEY, disableConnectDialogEditing)


#define SHORTCUTS_SETTINGS                                                                    \
	PROCESS(shortcuts, ENABLE_GLOBAL_SHORTCUTS_KEY, bShortcutEnable)                          \
	PROCESS(shortcuts, SUPPRESS_MACOS_EVENT_TAPPING_WARNING_KEY, bSuppressMacEventTapWarning)


#define SEARCH_SETTINGS                                             \
	PROCESS(search, SEARCH_FOR_USERS_KEY, searchForUsers)           \
	PROCESS(search, SEARCH_FOR_CHANNELS_KEY, searchForChannels)     \
	PROCESS(search, SEARCH_CASE_SENSITIVE_KEY, searchCaseSensitive) \
	PROCESS(search, SEARCH_REGEX_KEY, searchAsRegex)                \
	PROCESS(search, DISPLAY_SEARCH_OPTIONS_KEY, searchOptionsShown) \
	PROCESS(search, SEARCH_USER_ACTION_KEY, searchUserAction)       \
	PROCESS(search, SEARCH_CHANNEL_ACTION_KEY, searchChannelAction) \
	PROCESS(search, SEARCH_WINDOW_POSITION_KEY, searchDialogPosition)


#define PROCESS_ALL_SETTINGS   \
	MISC_SETTINGS              \
	AUDIO_SETTINGS             \
	IDLE_SETTINGS              \
	POSITIONAL_AUDIO_SETTINGS  \
	NETWORK_SETTINGS           \
	AUDIO_BACKEND_SETTINGS     \
	TTS_SETTINGS               \
	PRIVACY_SETTINGS           \
	UI_SETTINGS                \
	UPDATE_SETTINGS            \
	LAST_CONNECTION_SETTINGS   \
	TALKINGUI_SETTINGS         \
	CHANNEL_HIERARCHY_SETTINGS \
	MANUAL_PLUGIN_SETTINGS     \
	PTT_WINDOW_SETTINGS        \
	RECORDING_SETTINGS         \
	HIDDEN_SETTINGS            \
	SHORTCUTS_SETTINGS         \
	SEARCH_SETTINGS


#define PROCESS_ALL_SETTINGS_WITH_INTERMEDIATE_OPERATION \
	MISC_SETTINGS                                        \
	INTERMEDIATE_OPERATION                               \
	AUDIO_SETTINGS                                       \
	INTERMEDIATE_OPERATION                               \
	IDLE_SETTINGS                                        \
	INTERMEDIATE_OPERATION                               \
	POSITIONAL_AUDIO_SETTINGS                            \
	INTERMEDIATE_OPERATION                               \
	NETWORK_SETTINGS                                     \
	INTERMEDIATE_OPERATION                               \
	AUDIO_BACKEND_SETTINGS                               \
	INTERMEDIATE_OPERATION                               \
	TTS_SETTINGS                                         \
	INTERMEDIATE_OPERATION                               \
	PRIVACY_SETTINGS                                     \
	INTERMEDIATE_OPERATION                               \
	UI_SETTINGS                                          \
	INTERMEDIATE_OPERATION                               \
	UPDATE_SETTINGS                                      \
	INTERMEDIATE_OPERATION                               \
	LAST_CONNECTION_SETTINGS                             \
	INTERMEDIATE_OPERATION                               \
	TALKINGUI_SETTINGS                                   \
	INTERMEDIATE_OPERATION                               \
	CHANNEL_HIERARCHY_SETTINGS                           \
	INTERMEDIATE_OPERATION                               \
	MANUAL_PLUGIN_SETTINGS                               \
	INTERMEDIATE_OPERATION                               \
	PTT_WINDOW_SETTINGS                                  \
	INTERMEDIATE_OPERATION                               \
	RECORDING_SETTINGS                                   \
	INTERMEDIATE_OPERATION                               \
	HIDDEN_SETTINGS                                      \
	INTERMEDIATE_OPERATION                               \
	SHORTCUTS_SETTINGS                                   \
	INTERMEDIATE_OPERATION                               \
	SEARCH_SETTINGS                                      \
	INTERMEDIATE_OPERATION


#endif // MUMBLE_MUMBLE_SETTINGS_MACROS_H_
