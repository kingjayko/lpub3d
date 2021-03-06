/*

NsisMultiUser.nsh - NSIS plugin that allows "per-user" (no admin required) and "per-machine" (asks elevation *only when necessary*) installations

Full source code, documentation and demos at https://github.com/Drizin/NsisMultiUser/

Copyright 2016-2017 Ricardo Drizin, Alex Mitev

*/

!verbose push
!verbose 3

; Standard NSIS header files
!include nsDialogs.nsh
!include LogicLib.nsh
!include WinVer.nsh
!include FileFunc.nsh
!include UAC.nsh

RequestExecutionLevel user ; will ask elevation only if necessary

; exit and error codes
!define MULTIUSER_ERROR_INVALID_PARAMETERS 666660 ; invalid command-line parameters
!define MULTIUSER_ERROR_ELEVATION_NOT_ALLOWED 666661 ; elevation is restricted by MULTIUSER_INSTALLMODE_ALLOW_ELEVATION or MULTIUSER_INSTALLMODE_ALLOW_ELEVATION_IF_SILENT
!define MULTIUSER_ERROR_NOT_INSTALLED 666662 ; returned from uninstaller when no version is installed
!define MULTIUSER_ERROR_ELEVATION_FAILED 666666 ; returned by the outer instance when the inner instance cannot start (user aborted elevation dialog, Logon service not running, UAC is not supported by the OS, user without admin priv. is used in the runas dialog), or started, but was not admin
!define MULTIUSER_INNER_INSTANCE_BACK 666667 ; returned by the inner instance when the user presses the Back button on the first visible page (display outer instance)

!macro MULTIUSER_INIT_VARS
	; required defines - [LPub3D, add COMPANY_NAME to required]
	!ifndef COMPANY_NAME | PRODUCT_NAME | VERSION | PROGEXE
		!error "Should define all variables: COMPANY_NAME, PRODUCT_NAME, VERSION, PROGEXE"
	!endif

	; optional defines
	; COMPANY_NAME - [LPub3D, moved to required] stored in uninstall info in registry
	; MULTIUSER_INSTALLMODE_NO_HELP_DIALOG - don't show help dialog

	!define /ifndef MULTIUSER_INSTALLMODE_ALLOW_BOTH_INSTALLATIONS 1 ; 0 or 1 - whether user can install BOTH per-user and per-machine; this only affects the texts and the required elevation on the page, the actual uninstall of previous version has to be implemented by script
	!define /ifndef MULTIUSER_INSTALLMODE_ALLOW_ELEVATION 1 ; 0 or 1, allow UAC screens in the (un)installer - if set to 0 and user is not admin, per-machine radiobutton will be disabled, or if elevation is always required, (un)installer will exit with an error code (and message if not silent)
	!if "${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION}" == "" ; old code - just defined with no value, equivalent to 1
		!define /redef MULTIUSER_INSTALLMODE_ALLOW_ELEVATION 1
	!endif
	!define /ifndef MULTIUSER_INSTALLMODE_ALLOW_ELEVATION_IF_SILENT 0 ; 0 or 1, (only available if MULTIUSER_INSTALLMODE_ALLOW_ELEVATION = 1) allow UAC screens in the (un)installer in silent mode; if set to 0 and user is not admin and elevation is always required, (un)installer will exit with an error code
	!if "${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION}" == 0
		!if "${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION_IF_SILENT}" == 1
			!error "MULTIUSER_INSTALLMODE_ALLOW_ELEVATION_IF_SILENT can be set only when MULTIUSER_INSTALLMODE_ALLOW_ELEVATION is set!"
		!endif
	!endif
	!define /ifndef MULTIUSER_INSTALLMODE_DEFAULT_ALLUSERS 0 ; 0 or 1, (only available if MULTIUSER_INSTALLMODE_ALLOW_ELEVATION = 1 and there are 0 or 2 installations on the system) when running as user and is set to 1, per-machine installation is pre-selected, otherwise per-user installation
	!if "${MULTIUSER_INSTALLMODE_DEFAULT_ALLUSERS}" == "" ; old code - just defined with no value, equivalent to 1
		!define /redef MULTIUSER_INSTALLMODE_DEFAULT_ALLUSERS 1
	!endif
	!define /ifndef MULTIUSER_INSTALLMODE_DEFAULT_CURRENTUSER 0 ; 0 or 1, (only available if there are 0 or 2 installations on the system) when running as admin and is set to 1, per-user installation is pre-selected, otherwise per-machine installation
	!if "${MULTIUSER_INSTALLMODE_DEFAULT_CURRENTUSER}" == "" ; old code - just defined with no value, equivalent to 1
		!define /redef MULTIUSER_INSTALLMODE_DEFAULT_CURRENTUSER 1
	!endif
	!define /ifndef MULTIUSER_INSTALLMODE_64_BIT 0 ; set to 1 for 64-bit installers
	!define /ifndef MULTIUSER_INSTALLMODE_INSTDIR "${PRODUCT_NAME}" ; suggested name of directory to install (under $PROGRAMFILES32/$PROGRAMFILES64 or $LOCALAPPDATA)

	!define /ifndef MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY "${PRODUCT_NAME}" ; registry key for UNINSTALL info, placed under [HKLM|HKCU]\Software\Microsoft\Windows\CurrentVersion\Uninstall	(can be ${PRODUCT_NAME} or some {GUID})
	!define /ifndef MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY "Microsoft\Windows\CurrentVersion\Uninstall\${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY}" ; registry key where InstallLocation is stored, placed under [HKLM|HKCU]\Software (can be ${PRODUCT_NAME} or some {GUID})
	!define MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH "Software\Microsoft\Windows\CurrentVersion\Uninstall\${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY}" ; full path to registry key storing uninstall information displayed in Windows installed programs list
	!define MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY_PATH "Software\${MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY}" ; full path to registry key where InstallLocation is stored
    !define MULTIUSER_INSTALLMODE_LEGACY_INSTALL_REGISTRY_KEY_PATH "Software\${COMPANY_NAME}\${PRODUCT_NAME}\Installation" ; full path to registry key where LPub3D Legacy InstallPath is stored
	!define /ifndef UNINSTALL_FILENAME "uninstall.exe" ; name of uninstaller
	!define /ifndef MULTIUSER_INSTALLMODE_DISPLAYNAME "${PRODUCT_NAME} ${VERSION}" ; display name in Windows uninstall list of programs
	!define /ifndef MULTIUSER_INSTALLMODE_INSTDIR_REGISTRY_VALUENAME "InstallLocation" ; name of the registry value containing install directory
	!define /date NOW "%Y%m%d"   ;[LPub3D, capture InstallDate]

	!ifdef MULTIUSER_INSTALLMODE_FUNCTION
		!define MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION ${MULTIUSER_INSTALLMODE_FUNCTION} ; old code - changed function name
		!undef MULTIUSER_INSTALLMODE_FUNCTION
	!endif

	; Variables
	Var MultiUser.Privileges ; Current user level: "Admin", "Power" (up to Windows XP), or else regular user.
	Var MultiUser.InstallMode ; Current Install Mode ("AllUsers" or "CurrentUser")
	Var IsAdmin ; 0 or 1, initialized via UserInfo::GetAccountType
	Var IsInnerInstance ; 0 or 1, initialized via UAC_IsInnerInstance
	Var HasLegacyPerMachineInstallation ; 0 or 1 - [LPub3D, legacy LPub3D installation - version 2.0.20 and older]
	Var HasPerMachineInstallation ; 0 or 1
	Var HasPerUserInstallation ; 0 or 1
	Var HasCurrentModeInstallation ; 0 or 1
	Var PerMachineInstallationVersion ; contains version number of empty string ""
	Var PerUserInstallationVersion ; contains version number of empty string ""
	Var PerMachineInstallationFolder
	Var PerUserInstallationFolder
	Var PerMachineUninstallString
	Var PerUserUninstallString
	Var PerMachineOptionAvailable ; 0 or 1: 0 means only per-user radio button is enabled on page, 1 means both; will be 0 only when MULTIUSER_INSTALLMODE_ALLOW_ELEVATION = 0 and user is not admin
	Var InstallShowPagesBeforeComponents ; 0 or 1, when 0, use it to hide all pages before Components inside the installer when running as inner instance
	Var DisplayDialog ; (internal)
	Var PreFunctionCalled ; (internal)
	Var CmdLineInstallMode ; contains command-line install mode set via /allusers and /currentusers parameters
	Var CmdLineDir ; contains command-line directory set via /D parameter

	; interface variables
	Var MultiUser.InstallModePage
	Var MultiUser.InstallModePage.Text
	Var MultiUser.InstallModePage.AllUsers
	Var MultiUser.InstallModePage.CurrentUser
	Var MultiUser.InstallModePage.AllUsersLabel
	Var MultiUser.InstallModePage.CurrentUserLabel
	Var MultiUser.InstallModePage.Description
!macroend

!macro MULTIUSER_UNINIT_VARS
	!ifdef MULTIUSER_INSTALLMODE_UNFUNCTION
		!define MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION ${MULTIUSER_INSTALLMODE_UNFUNCTION} ; old code - changed function name
		!undef MULTIUSER_INSTALLMODE_UNFUNCTION
	!else ifdef MULTIUSER_INSTALLMODE_CHANGE_MODE_UNFUNCTION
		!define MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION ${MULTIUSER_INSTALLMODE_CHANGE_MODE_UNFUNCTION} ; old code - changed function name
		!undef MULTIUSER_INSTALLMODE_CHANGE_MODE_UNFUNCTION
	!endif

	; Variables
	Var UninstallShowBackButton ; 0 or 1, use it to show/hide the Back button on the first visible page of the uninstaller
!macroend

/****** Modern UI 2 page ******/
!macro MULTIUSER_PAGE UNINSTALLER_PREFIX UNINSTALLER_FUNCPREFIX
	!ifdef MULTIUSER_${UNINSTALLER_PREFIX}PAGE_INSTALLMODE
		!error "You cannot insert MULTIUSER_${UNINSTALLER_PREFIX}PAGE_INSTALLMODE more than once!"
	!endif
	!define MULTIUSER_${UNINSTALLER_PREFIX}PAGE_INSTALLMODE

	!ifmacrodef MUI_${UNINSTALLER_PREFIX}PAGE_INIT
		!insertmacro MUI_${UNINSTALLER_PREFIX}PAGE_INIT
	!endif

	!insertmacro MULTIUSER_${UNINSTALLER_PREFIX}INIT_VARS

	!insertmacro MULTIUSER_FUNCTION_INSTALLMODEPAGE "${UNINSTALLER_PREFIX}" "${UNINSTALLER_FUNCPREFIX}"

	PageEx ${UNINSTALLER_FUNCPREFIX}custom
		PageCallbacks ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModePre ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeLeave
	PageExEnd

	!ifmacrodef MUI_${UNINSTALLER_PREFIX}PAGE_END
		!insertmacro MUI_${UNINSTALLER_PREFIX}PAGE_END ; MUI1 MUI_UNPAGE_END macro
	!endif
!macroend

!macro MULTIUSER_PAGE_INSTALLMODE ; create install page - called by user script
	!insertmacro MULTIUSER_PAGE "" ""
!macroend

!macro MULTIUSER_UNPAGE_INSTALLMODE ; create uninstall page - called by user script
	!ifndef MULTIUSER_PAGE_INSTALLMODE
		!error "You have to insert MULTIUSER_PAGE_INSTALLMODE before MULTIUSER_UNPAGE_INSTALLMODE!"
	!endif
	!insertmacro MULTIUSER_PAGE "UN" "un."
!macroend

/****** Installer/uninstaller initialization ******/
!macro MULTIUSER_INIT ; called by user script in .onInit (after MULTIUSER_PAGE_INSTALLMODE)
	!ifdef MULTIUSER_INIT
		!error "MULTIUSER_INIT already inserted!"
	!endif
	!define MULTIUSER_INIT

	!ifndef MULTIUSER_PAGE_INSTALLMODE
		!error "You have to insert MULTIUSER_PAGE_INSTALLMODE!"
	!endif

	Call MultiUser.InitChecks
!macroend

!macro MULTIUSER_UNINIT ; called by user script in un.onInit (after MULTIUSER_UNPAGE_INSTALLMODE)
	!ifdef MULTIUSER_UNINIT
		!error "MULTIUSER_UNINIT already inserted!"
	!endif
	!define MULTIUSER_UNINIT

	!ifndef MULTIUSER_PAGE_INSTALLMODE | MULTIUSER_UNPAGE_INSTALLMODE
		!error "You have to insert both MULTIUSER_PAGE_INSTALLMODE and MULTIUSER_UNPAGE_INSTALLMODE!"
	!endif

	Call un.MultiUser.InitChecks
!macroend

/****** Functions ******/
!macro MULTIUSER_FUNCTION_INSTALLMODEPAGE UNINSTALLER_PREFIX UNINSTALLER_FUNCPREFIX
	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
		${if} $MultiUser.InstallMode == "AllUsers"
			Return
		${endif}

		StrCpy $MultiUser.InstallMode "AllUsers"

		SetShellVarContext all

		StrCpy $HasCurrentModeInstallation "$HasPerMachineInstallation"

		${if} $CmdLineDir != ""
			StrCpy $INSTDIR $CmdLineDir
		${elseif} $PerMachineInstallationFolder != ""
			StrCpy $INSTDIR $PerMachineInstallationFolder
		${else}
			!if "${UNINSTALLER_FUNCPREFIX}" == ""
				; Set default installation location for installer
				${if} ${MULTIUSER_INSTALLMODE_64_BIT} == 0
					StrCpy $INSTDIR "$PROGRAMFILES32\${MULTIUSER_INSTALLMODE_INSTDIR}"
				${else}
					StrCpy $INSTDIR "$PROGRAMFILES64\${MULTIUSER_INSTALLMODE_INSTDIR}"
				${endif}
			!endif
		${endif}

		!ifdef MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION
			Call "${MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION}"
		!endif
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
		${if} $MultiUser.InstallMode == "CurrentUser"
			Return
		${endif}

		StrCpy $MultiUser.InstallMode "CurrentUser"

		SetShellVarContext current

		StrCpy $HasCurrentModeInstallation "$HasPerUserInstallation"

		${if} $CmdLineDir != ""
			StrCpy $INSTDIR $CmdLineDir
		${elseif} $PerUserInstallationFolder != ""
			StrCpy $INSTDIR $PerUserInstallationFolder
		${else}
			!if "${UNINSTALLER_FUNCPREFIX}" == ""
				; Set default installation location for installer
				${if} "$LOCALAPPDATA" != ""
					; There is a shfolder.dll that emulates CSIDL_LOCAL_APPDATA for older versions of shell32.dll which doesn't support it (pre-Win2k versions)
					; This shfolder.dll is bundeled with IE5 (or as part of Platform SDK Redistributable) that can be installed on NT4 and NSIS (at least since v3.01) will use it instead of shell32.dll if it is available
					StrCpy $INSTDIR "$LOCALAPPDATA\${MULTIUSER_INSTALLMODE_INSTDIR}"
				${else}
					; When shfolder.dll is unavailable on NT4 (and so $LOCALAPPDATA returns nothing), local AppData path can still be queried here using registry
					ReadRegStr $INSTDIR HKCU "SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" "Local AppData"
					${if} "$INSTDIR" == ""
						StrCpy $INSTDIR "$PROGRAMFILES32\${MULTIUSER_INSTALLMODE_INSTDIR}" ; there's no 64-bit of Windows before 2000 (i.e. NT4)
					${else}
						StrCpy $INSTDIR "$INSTDIR\${MULTIUSER_INSTALLMODE_INSTDIR}"
					${endif}
				${endif}
			!endif
		${endif}

		!ifdef MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION
			Call "${MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION}"
			!undef MULTIUSER_INSTALLMODE_CHANGE_MODE_FUNCTION
		!endif
	FunctionEnd

	!if ${MULTIUSER_INSTALLMODE_ALLOW_BOTH_INSTALLATIONS} == 0
		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			Function MultiUser.GetInstallMode
				; called by the inner instance via the UAC plugin to get InstallMode selected by user in outer instance
				; (UAC doesn't support passing custom parameters to the inner instance)
				StrCpy $0 $MultiUser.InstallMode
			FunctionEnd
		!endif
	!endif

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckPageElevationRequired
		; check if elevation on page is always required, return result in $0
		; when this function is called from InitChecks, InstallMode is ""
		; and when called from InstallModeLeave/SetShieldsAndTexts, InstallMode is not empty
		StrCpy $0 0
		${if} $IsAdmin == 0
			${if} $MultiUser.InstallMode == "AllUsers"
				StrCpy $0 1
			${else}
				!if "${UNINSTALLER_FUNCPREFIX}" == "" ; installer
					!if ${MULTIUSER_INSTALLMODE_ALLOW_BOTH_INSTALLATIONS} == 0
						${if} $HasPerMachineInstallation$HasPerUserInstallation == "10"
							StrCpy $0 1 ; has to uninstall the per-machine istalattion, which requires admin rights
						${endif}
					!endif
				!endif
			${endif}
		${endif}
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckElevationAllowed
		${if} ${silent}
			StrCpy $0 "${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION_IF_SILENT}"
		${else}
			StrCpy $0 "${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION}"
		${endif}

		${if} $0 == 0
			MessageBox MB_ICONSTOP "You need to run this program as administrator."	/SD IDOK
			SetErrorLevel ${MULTIUSER_ERROR_ELEVATION_NOT_ALLOWED}
			Quit
		${endif}
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.Elevate
		Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckElevationAllowed

		HideWindow
		!insertmacro UAC_RunElevated
		${if} $0 == 0
			; if inner instance was started ($1 == 1), return code of the elevated fork process is in $2 as well as set via SetErrorLevel
			; NOTE: the error level may have a value MULTIUSER_ERROR_ELEVATION_FAILED (but not MULTIUSER_ERROR_ELEVATION_NOT_ALLOWED)
			${if} $1 != 1 ; process did not start - return MULTIUSER_ERROR_ELEVATION_FAILED
				SetErrorLevel ${MULTIUSER_ERROR_ELEVATION_FAILED}
			${endif}
		${else} ; process did not start - return MULTIUSER_ERROR_ELEVATION_FAILED or Win32 error code stored in $0
			${if} $0 == 1223 ; user aborted elevation dialog - translate to MULTIUSER_ERROR_ELEVATION_FAILED for easier processing
				${orif} $0 == 1062 ; Logon service not running - translate to MULTIUSER_ERROR_ELEVATION_FAILED for easier processing
				StrCpy $0 ${MULTIUSER_ERROR_ELEVATION_FAILED}
			${endif}
			SetErrorLevel $0
		${endif}
		Quit
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InitChecks
		Push "$R0"
		Push "$R1"
		Push "$0"

		; Installer initialization - check privileges and set default install mode
		StrCpy $MultiUser.InstallMode ""
		StrCpy $PerMachineOptionAvailable 1
		StrCpy $InstallShowPagesBeforeComponents 1
		StrCpy $DisplayDialog 1
		StrCpy $PreFunctionCalled 0
		StrCpy $CmdLineInstallMode ""
		StrCpy $CmdLineDir ""

		; [LPub3D, Always use the 64-bit registry. SetRegView is only available on x86_64 platforms]
		${if} ${RunningX64}
			${if} ${MULTIUSER_INSTALLMODE_64_BIT} == 0
				SetRegView 32 ; someday, when NSIS is 64-bit...
			${else}
				SetRegView 64
			${endif}
		${endif}

		UserInfo::GetAccountType
		Pop $MultiUser.Privileges
		${if} $MultiUser.Privileges == "Admin"
			${orif} $MultiUser.Privileges == "Power" ; under XP (and earlier?), Power users can install programs, but UAC_IsAdmin returns false
			StrCpy $IsAdmin 1
		${else}
			StrCpy $IsAdmin 0
		${endif}

		${if} ${UAC_IsInnerInstance}
			StrCpy $IsInnerInstance 1
		${else}
			StrCpy $IsInnerInstance 0
		${endif}

		; initialize PerXXXInstallationVersion, PerXXXInstallationFolder, PerXXXUninstallString variables
		ReadRegStr $PerMachineInstallationVersion HKLM "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}" "DisplayVersion"
		ReadRegStr $PerMachineInstallationFolder HKLM "${MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY_PATH}" "${MULTIUSER_INSTALLMODE_INSTDIR_REGISTRY_VALUENAME}" ; "InstallLocation"
		ReadRegStr $PerMachineUninstallString HKLM "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}" "UninstallString" ; contains the /currentuser or /allusers parameter

		;[LPub3D, Legacy LPub3D Installation Check - Look for missing InstallLocation key in Uninstall\LPub3D hive]
		${if} $PerMachineInstallationFolder == ""
			;Machine installation returned null so check for LPub3D-specific legacy installation folder and version
			ReadRegStr $PerMachineInstallationFolder HKCU "${MULTIUSER_INSTALLMODE_LEGACY_INSTALL_REGISTRY_KEY_PATH}" "InstallPath" ; LPub3D Legacy "InstallPath"
			${if} $PerMachineInstallationFolder != ""
				;InstallPath defined so we have a Legacy installation, proceed to populate Version and InstallString
				StrCpy $HasLegacyPerMachineInstallation 1
				${If} ${RunningX64}
					SetRegView 32 ; On x86_64 platforms, legacy LPub3D installations create the uninstall hive in the 32bit (WoW6432Node) registry so look there
				${endif}
				ReadRegStr $PerMachineInstallationVersion HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayVersion"
				ReadRegStr $PerMachineUninstallString HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "UninstallString"
				${If} ${RunningX64}
					SetRegView 64 ; Don't forget to restore SetRegView to the 64bit hive
				${endif}
				StrCpy $PerMachineUninstallString "$PerMachineUninstallString /allusers"
			${else}
				StrCpy $HasLegacyPerMachineInstallation 0
			${endif}
		${endif}
		;End LPub3D Legacy Install

		${if} $PerMachineInstallationFolder == ""
			StrCpy $HasPerMachineInstallation 0
		${else}
			StrCpy $HasPerMachineInstallation 1
		${endif}

		ReadRegStr $PerUserInstallationVersion HKCU "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}" "DisplayVersion"
		ReadRegStr $PerUserInstallationFolder HKCU "${MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY_PATH}" "${MULTIUSER_INSTALLMODE_INSTDIR_REGISTRY_VALUENAME}" ; "InstallLocation"
		ReadRegStr $PerUserUninstallString HKCU "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}" "UninstallString" ; contains the /currentuser or /allusers parameter

		${if} $PerUserInstallationFolder == ""
			StrCpy $HasPerUserInstallation 0
		${else}
			StrCpy $HasPerUserInstallation 1
		${endif}

		; get all parameters
		${GetParameters} $R0

		; initialize CmdLineInstallMode and CmdLineDir, needed also if we are the inner instance (UAC passes all parameters from the outer instance)
		; note: the loading of the /D parameter depends on AllowRootDirInstall, see https://sourceforge.net/p/nsis/bugs/1176/
		${GetOptions} $R0 "/allusers" $R1
		${ifnot} ${errors}
			StrCpy $CmdLineInstallMode "AllUsers"
		${endif}

		${GetOptions} $R0 "/currentuser" $R1
		${ifnot} ${errors}
			${if} $CmdLineInstallMode != ""
				MessageBox MB_ICONSTOP "Provide only one of the /allusers or /currentuser parameters." /SD IDOK
				SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS}
				Quit
			${endif}
			StrCpy $CmdLineInstallMode "CurrentUser"
		${endif}

		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			${if} "$INSTDIR" != "" ; if $INSTDIR is not empty here in the installer, it's initialized with the value of the /D command-line parameter
				StrCpy $CmdLineDir "$INSTDIR"
			${endif}
		!endif

		; initialize $InstallShowPagesBeforeComponents and $UninstallShowBackButton
		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			${if} $IsInnerInstance == 1
				StrCpy $InstallShowPagesBeforeComponents 0 ; we hide pages only if we're the inner instance (the outer instance always shows them)
			${endif}
		!else
			${if} $CmdLineInstallMode == ""
				${andif} $HasPerMachineInstallation$HasPerUserInstallation == "11"
				StrCpy $UninstallShowBackButton 1 ; make sure we show Back button only if dialog was displayed, i.e. uninstaller did not elevate in the beginning (see when MultiUser.Elevate is called)
			${else}
				StrCpy $UninstallShowBackButton 0
			${endif}
		!endif

		${if} $IsInnerInstance == 1
			; check if the inner instance has admin rights
			${if} $IsAdmin == 0
				SetErrorLevel ${MULTIUSER_ERROR_ELEVATION_FAILED} ; special return value for outer instance so it knows we did not have admin rights
				Quit
			${endif}

			!if ${MULTIUSER_INSTALLMODE_ALLOW_BOTH_INSTALLATIONS} == 0
				!if "${UNINSTALLER_FUNCPREFIX}" == ""
					!insertmacro UAC_AsUser_Call Function MultiUser.GetInstallMode ${UAC_SYNCREGISTERS}
					${if} $0 == "CurrentUser"
						; the inner instance was elevated because there is installation per-machine, which needs to be removed and requires admin rights,
						; but the user selected per-user installation in the outer instance, set context to CurrentUser
						Call MultiUser.InstallMode.CurrentUser
						StrCpy $DisplayDialog 0
						Pop $0
						Pop $R1
						Pop $R0
						Return
					${endif}
				!endif
			!endif

			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers ; Inner Process (and Admin) - set to AllUsers
			StrCpy $DisplayDialog 0
			Pop $0
			Pop $R1
			Pop $R0
			Return
		${endif}

		; process /? parameter
		!ifndef MULTIUSER_INSTALLMODE_NO_HELP_DIALOG ; define MULTIUSER_INSTALLMODE_NO_HELP_DIALOG to display your own help dialog (new options, return codes, etc.)
			${GetOptions} $R0 "/?" $R1
			${ifnot} ${errors}
				MessageBox MB_ICONINFORMATION "Usage:$\r$\n$\r$\n\
					 /allusers$\t- (un)install for all users, case-insensitive$\r$\n\
					/currentuser - (un)install for current user only, case-insensitive$\r$\n\
					/uninstall$\t- (installer only) run uninstaller, requires /allusers or /currentuser, case-insensitive$\r$\n\
									/S$\t- silent mode, requires /allusers or /currentuser, case-sensitive$\r$\n\
									/D$\t- (installer only) set install directory, must be last parameter, without quotes, case-sensitive$\r$\n\
									/?$\t- display this message$\r$\n$\r$\n$\r$\n\
				Return codes (decimal):$\r$\n$\r$\n\
						 0$\t- normal execution (no error)$\r$\n\
						 1$\t- (un)installation aborted by user (Cancel button)$\r$\n\
						 2$\t- (un)installation aborted by script$\r$\n\
				666660$\t- invalid command-line parameters$\r$\n\
				666661$\t- elevation is not allowed by defines$\r$\n\
				666662$\t- uninstaller detected there's no installed version$\r$\n\
				666663$\t- executing uninstaller from the installer failed$\r$\n\
				666666$\t- cannot start elevated instance$\r$\n\
				 other$\t- Windows error code when trying to start elevated instance"
				SetErrorLevel 0
				Quit
			${endif}
		!endif

		; process /uninstall parameter
		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			${GetOptions} $R0 "/uninstall" $R1
			${ifnot} ${errors}
				${if} $CmdLineInstallMode == ""
					MessageBox MB_ICONSTOP "Provide one of the /allusers or /currentuser parameters." /SD IDOK
					SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS}
					Quit
				${endif}

				${if} $CmdLineInstallMode == "AllUsers"
					${if} $HasPerMachineInstallation == 0
						MessageBox MB_ICONSTOP "There is no per-machine installation of ${PRODUCT_NAME}." /SD IDOK
						SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS}
						Quit
					${endif}
					StrCpy $0 "$PerMachineInstallationFolder"
				${else}
					${if} $HasPerUserInstallation == 0
						MessageBox MB_ICONSTOP "There is no per-user installation of ${PRODUCT_NAME}." /SD IDOK
						SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS}
						Quit
					${endif}
					StrCpy $0 "$PerUserInstallationFolder"
				${endif}

				; NOTES:
				; - the _? param stops the uninstaller from copying itself to the temporary directory, which is the only way for waiting to work
				; - $R0 passes the original parameters from the installer to the uninstaller (together with /uninstall so that uninstaller knows installer is running and skips opitional single instance checks)
				; - using ExecWait fails if the new process requires elevation, see http://forums.winamp.com/showthread.php?p=3080202&posted=1#post3080202, so we use ShellExecuteEx
				System::Call '*(i 60, i 0x140, i 0, t "open", t "$0\${UNINSTALL_FILENAME}", t "$R0 _?=$0", t, i ${SW_SHOW}, i, i, t, i, i, i, i) p .r2' ; allocate and fill values for SHELLEXECUTEINFO structure, returned in $2 (0x140 = SEE_MASK_NOCLOSEPROCESS|SEE_MASK_NOASYNC)

				System::Call 'shell32::ShellExecuteEx(i r2) i .r0 ?e'
				Pop $1
				${if} $0 == 0
					SetErrorLevel $1
					Quit
				${endif}

				System::Call '*$2(i, i, i, t, t, t, t, i, i, i, t, i, i, i, i .r3)' ; get the process handle in $3

				System::Call 'kernel32::WaitForSingleObject(i r3, i -1) i .r0 ?e' ; wait indefinitely for the process to exit
				Pop $1
				${if} $0 != 0 ; WAIT_OBJECT_0
					SetErrorLevel $1
					Quit
				${endif}

				System::Call 'kernel32::GetExitCodeProcess(i r3, *i .r4) i .r0 ?e' ; store exit code in $4
				Pop $1
				${if} $0 == 0
					SetErrorLevel $1
					Quit
				${endif}

				System::Call 'Kernel32::CloseHandle(i r3)' ; close the process handle in $3
				System::Free $2 ; free SHELLEXECUTEINFO structure, stored in $2

				SetErrorLevel $4 ; return exit code stored in $4
				Quit
			${endif}
		!endif

		; check for limitations
		${if} ${silent}
			${andif} $CmdLineInstallMode == ""
			SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS} ; one of the /allusers or /currentuser parameters is required in silent mode
			Quit
		${endif}

		!if "${UNINSTALLER_FUNCPREFIX}" != ""
			${if} $HasPerMachineInstallation$HasPerUserInstallation == "00"
				MessageBox MB_ICONSTOP "There is no installation of ${PRODUCT_NAME}." /SD IDOK
				SetErrorLevel ${MULTIUSER_ERROR_NOT_INSTALLED}
				Quit
			${endif}
		!endif

		; process /allusers and /currentuser parameters (both silent and non-silent mode, installer and uninstaller)
		${if} $CmdLineInstallMode != ""
			${ifnot} ${IsNT} ; Not running Windows NT, (so it's Windows 95/98/ME), so per-user installation not supported
				${andif} $CmdLineInstallMode == "CurrentUser"
				MessageBox MB_ICONSTOP "The OS doesn't support per-user installations." /SD IDOK
				SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS}
				Quit
			${endif}

			${if} $CmdLineInstallMode == "AllUsers"
				Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
			${else}
				Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
			${endif}

			!if "${UNINSTALLER_FUNCPREFIX}" != ""
				${if} $HasCurrentModeInstallation == 0
					MessageBox MB_ICONSTOP "There is no $CmdLineInstallMode installation of ${PRODUCT_NAME}." /SD IDOK
					SetErrorLevel ${MULTIUSER_ERROR_INVALID_PARAMETERS}
					Quit
				${endif}
			!endif

			!if "${UNINSTALLER_FUNCPREFIX}" != ""
				StrCpy $DisplayDialog 0 ; uninstaller - don't display dialog when there is /allusers or /currentuser parameter
			!else
				${if} ${silent}
					StrCpy $DisplayDialog 0
				${endif}
			!endif

			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckPageElevationRequired
			${if} $0 == 1
				${if} $DisplayDialog == 0 ; if we are not displaying the dialog (uninstaller or silent mode) and elevation is required, Elevate now (or Quit with an error)
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.Elevate
				${else}
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckElevationAllowed ; if we are displaying the dialog and elevation is required, check if elevation is allowed
				${endif}
			${endif}
			Pop $0
			Pop $R1
			Pop $R0
			Return
		${endif}

		; the rest of the code is executed only when there are no /allusers and /currentuser parameters and in non-silent mode
		${ifnot} ${IsNT} ; Not running Windows NT, (so it's Windows 95/98/ME), so per-user installation not supported
			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
			StrCpy $DisplayDialog 0
			Pop $0
			Pop $R1
			Pop $R0
			Return
		${endif}

		; check if elevation on page is always required (installer only)
		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckPageElevationRequired
			${if} $0 == 1
				Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckElevationAllowed
			${endif}
		!endif

		; if elevation is not allowed and user is not admin, disable the per-machine option
		!if ${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION} == 0
			${if} $IsAdmin == 0
				StrCpy $PerMachineOptionAvailable 0
			${endif}
		!endif

		; if there's only one installed version
		; when uninstaller is invoked from the "add/remove programs", Windows will automatically start uninstaller elevated if uninstall keys are in HKLM
		${if} $HasPerMachineInstallation$HasPerUserInstallation == "10"
			!if "${UNINSTALLER_FUNCPREFIX}" == ""
				${if} $PerMachineOptionAvailable == 1
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
				${else}
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
				${endif}
			!else
				${if} $IsAdmin == 0
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.Elevate ; if $PerMachineOptionAvailable = 0 (i.e. MULTIUSER_INSTALLMODE_ALLOW_ELEVATION = 0), Elevate will call CheckElevationAllowed, which checks if MULTIUSER_INSTALLMODE_ALLOW_ELEVATION = 0
				${endif}
				Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
				StrCpy $DisplayDialog 0
			!endif
		${elseif} $HasPerMachineInstallation$HasPerUserInstallation == "01"
			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
			!if "${UNINSTALLER_FUNCPREFIX}" != ""
				StrCpy $DisplayDialog 0
			!endif
		${else} ; if there is no installed version (installer only), or there are 2 installations - we always display the dialog
			${if} $IsAdmin == 1 ; If running as admin, default to per-machine installation (unless default is forced by MULTIUSER_INSTALLMODE_DEFAULT_CURRENTUSER)
				!if ${MULTIUSER_INSTALLMODE_DEFAULT_CURRENTUSER} == 0
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
				!else
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
				!endif
			${else} ; if not running as admin, default to per-user installation (unless default is forced by MULTIUSER_INSTALLMODE_DEFAULT_ALLUSERS)
				!if ${MULTIUSER_INSTALLMODE_DEFAULT_ALLUSERS} == 0
					Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
				!else
					${if} $PerMachineOptionAvailable == 1
						Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
					${else}
						Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
					${endif}
				!endif
			${endif}
		${endif}

		Pop $0
		Pop $R1
		Pop $R0
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModePre
		Push "$0"
		Push "$1"

		${if} $IsInnerInstance == 1
			${andif} $PreFunctionCalled == 1
			; user pressed Back button on the first visible page in the inner instance - display outer instance
			SetErrorLevel ${MULTIUSER_INNER_INSTANCE_BACK}
			Quit
		${endif}
		StrCpy $PreFunctionCalled 1

		${if} $DisplayDialog == 0
			Abort
		${endif}

		!ifmacrodef MUI_HEADER_TEXT
			!if "${UNINSTALLER_FUNCPREFIX}" == ""
				!insertmacro MUI_HEADER_TEXT "Choose Installation Options" "Who should this application be installed for?"
			!else
				!insertmacro MUI_HEADER_TEXT "Choose Uninstallation Options" "Which installation should be removed?"
			!endif
		!endif

		!ifdef MUI_PAGE_CUSTOMFUNCTION_PRE
			Call "${MUI_PAGE_CUSTOMFUNCTION_PRE}"
			!undef MUI_PAGE_CUSTOMFUNCTION_PRE
		!endif
		nsDialogs::Create 1018
		Pop $MultiUser.InstallModePage

		; default was MULTIUSER_TEXT_INSTALLMODE_TITLE "Choose Users"
		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			${NSD_CreateLabel} 0 0 100% 24u "Please, select whether you wish to make this software available to all users or just yourself."
		!else
			${NSD_CreateLabel} 0 0 100% 24u "This software is installed both per-machine (all users) and per-user. $\r$\nWhich installation you wish to remove?"
		!endif
		Pop $MultiUser.InstallModePage.Text

		StrCpy $0 "Anyone who uses this computer (all users)"
		${NSD_CreateRadioButton} 30u 30% 10u 8u ""
		Pop $MultiUser.InstallModePage.AllUsers

		System::Call "advapi32::GetUserName(t.r1,*i${NSIS_MAX_STRLEN})i"
		StrCpy $1 "Only for me ($1)"
		${NSD_CreateRadioButton} 30u 45% 10u 8u ""
		Pop $MultiUser.InstallModePage.CurrentUser

		; We create the radio buttons with empty text and create separate labels, because radio button font color can't be changed with XP Styles turned on,
		; which creates problems with UMUI themes, see http://forums.winamp.com/showthread.php?p=3079742#post3079742
		; shortcuts (&) for labels don't work and cause strange behaviour in NSIS - going to another page, etc.
		${NSD_CreateLabel} 44u 30% 280u 8u "$0"
		Pop $MultiUser.InstallModePage.AllUsersLabel
		nsDialogs::SetUserData $MultiUser.InstallModePage.AllUsersLabel $MultiUser.InstallModePage.AllUsers
		${NSD_CreateLabel} 44u 45% 280u 8u "$1"
		Pop $MultiUser.InstallModePage.CurrentUserLabel
		nsDialogs::SetUserData $MultiUser.InstallModePage.CurrentUserLabel $MultiUser.InstallModePage.CurrentUser

		${if} $PerMachineOptionAvailable == 0 ; install per-machine is not available
			SendMessage $MultiUser.InstallModePage.AllUsersLabel ${WM_SETTEXT} 0 "STR:$0 (must run as admin)" ; only when $PerMachineOptionAvailable == 0, we add that comment to the disabled control itself
			${orif} $CmdLineInstallMode != ""
			EnableWindow $MultiUser.InstallModePage.AllUsersLabel 0 ; start out disabled
			EnableWindow $MultiUser.InstallModePage.AllUsers 0 ; start out disabled
		${endif}

		${if} $CmdLineInstallMode != ""
			EnableWindow $MultiUser.InstallModePage.CurrentUserLabel 0
			EnableWindow $MultiUser.InstallModePage.CurrentUser 0
		${endif}

		; bind to label click
		${NSD_OnClick} $MultiUser.InstallModePage.CurrentUserLabel ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionLabelClick
		${NSD_OnClick} $MultiUser.InstallModePage.AllUsersLabel ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionLabelClick

		; bind to radiobutton change
		${NSD_OnClick} $MultiUser.InstallModePage.CurrentUser ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionClick
		${NSD_OnClick} $MultiUser.InstallModePage.AllUsers ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionClick

		${NSD_CreateLabel} 0u -32u 100% 32u "" ; will hold up to 4 lines of text
		Pop $MultiUser.InstallModePage.Description

		${if} $MultiUser.InstallMode == "AllUsers" ; setting selected radio button
			SendMessage $MultiUser.InstallModePage.AllUsers ${BM_SETCHECK} ${BST_CHECKED} 0 ; select radio button
		${else}
			SendMessage $MultiUser.InstallModePage.CurrentUser ${BM_SETCHECK} ${BST_CHECKED} 0 ; select radio button
		${endif}
		Call ${UNINSTALLER_FUNCPREFIX}MultiUser.SetShieldAndTexts ; simulating click on the control will change $INSTDIR and reset a possible user selection

		!ifmacrodef UMUI_IOPAGEBGTRANSPARENT_INIT ; UMUI, apply theme to controls
			!ifndef USE_MUIEx ; for MUIEx, applying themes causes artifacts
				!insertmacro UMUI_IOPAGEBGTRANSPARENT_INIT $MultiUser.InstallModePage
				!insertmacro UMUI_IOPAGECTLTRANSPARENT_INIT $MultiUser.InstallModePage.Text
				!insertmacro UMUI_IOPAGECTLTRANSPARENT_INIT $MultiUser.InstallModePage.AllUsers
				!insertmacro UMUI_IOPAGECTLTRANSPARENT_INIT $MultiUser.InstallModePage.AllUsersLabel
				!insertmacro UMUI_IOPAGECTLTRANSPARENT_INIT $MultiUser.InstallModePage.CurrentUser
				!insertmacro UMUI_IOPAGECTLTRANSPARENT_INIT $MultiUser.InstallModePage.CurrentUserLabel
				!insertmacro UMUI_IOPAGECTLTRANSPARENT_INIT $MultiUser.InstallModePage.Description
			!endif
		!endif

		Pop $1
		Pop $0

		!ifdef MUI_PAGE_CUSTOMFUNCTION_SHOW
			Call "${MUI_PAGE_CUSTOMFUNCTION_SHOW}"
			!undef MUI_PAGE_CUSTOMFUNCTION_SHOW
		!endif

		nsDialogs::Show

		!if "${UNINSTALLER_FUNCPREFIX}" == ""
			Push "$0"
			GetDlgItem $0 $HWNDPARENT 1
			SendMessage $0 ${BCM_SETSHIELD} 0 0 ; hide SHIELD	on page leave (InstallModeLeave is called only on Next button click)
			Pop $0
		!endif
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeLeave
		Push "$0"
		Push "$1"
		Push "$2"
		Push "$3"

		!if ${MULTIUSER_INSTALLMODE_ALLOW_ELEVATION} == 1 ; if elevation is allowed
			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckPageElevationRequired

			${if} $0 == 1
				HideWindow
				!insertmacro UAC_RunElevated
				;MessageBox MB_OK "[$0]/[$1]/[$2]/[$3]"

				; http://nsis.sourceforge.net/UAC_plug-in
				${Switch} $0
					${Case} 0
						${Switch} $1
							${Case} 1	; Started an elevated child process successfully, exit code is in $2
								${Switch} $2
									${Case} ${MULTIUSER_ERROR_ELEVATION_FAILED} ; the inner instance was not admin after all - stay on page
										MessageBox MB_ICONSTOP "You need to login with an account that is a member of the admin group to continue." /SD IDOK
										${Break}
									${Case} ${MULTIUSER_INNER_INSTANCE_BACK} ; if user pressed Back button on the first visible page of the inner instance - stay on page
										${Break}
									${Default} ; all other cases - Quit
										; return code of the elevated fork process is in $2 as well as set via SetErrorLevel
										Quit
								${EndSwitch}
								${Break}
							${Case} 3 ; RunAs completed successfully, but with a non-admin user - stay on page
								MessageBox MB_ICONSTOP "You need to login with an account that is a member of the admin group to continue." /SD IDOK
								${Break}
							${Default} ; 0 - UAC is not supported by the OS, OR 2 - The process is already running @ HighIL (Member of admin group) - stay on page
								MessageBox MB_ICONSTOP "Elevation is not supported by your operating system." /SD IDOK
						${EndSwitch}
						${Break}
					${Case} 1223 ; user aborted elevation dialog - stay on page
						${Break}
					${Case} 1062 ; Logon service not running - stay on page
						MessageBox MB_ICONSTOP "Unable to elevate, Secondary Logon service not running" /SD IDOK
						${Break}
					${Default} ; anything else should be treated as a fatal error - stay on page
						MessageBox MB_ICONSTOP "Unable to elevate, error $0" /SD IDOK
				${EndSwitch}

				; clear the error level set by UAC for inner instance, so that outer instance returns its own error level when exits (the error level is not reset by NSIS if once set and >= 0)
				; see http://forums.winamp.com/showthread.php?p=3079116&posted=1#post3079116
				SetErrorLevel -1
				BringToFront
				Abort ; Stay on page
			${endif}
		!endif

		Pop $3
		Pop $2
		Pop $1
		Pop $0

		!ifdef MUI_PAGE_CUSTOMFUNCTION_LEAVE
			Call "${MUI_PAGE_CUSTOMFUNCTION_LEAVE}"
			!undef MUI_PAGE_CUSTOMFUNCTION_LEAVE
		!endif
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.SetShieldAndTexts
		Push "$0"
		Push "$1"
		Push "$2"

		GetDlgItem $1 $hwndParent 1 ; get item 1 (next button) at parent window, store in $1 - (0 is back, 1 is next .. what about CANCEL? http://nsis.sourceforge.net/Buttons_Header )

		Call ${UNINSTALLER_FUNCPREFIX}MultiUser.CheckPageElevationRequired
		SendMessage $1 ${BCM_SETSHIELD} 0 $0 ; display/hide SHIELD (Windows Vista and above)

		StrCpy $0 "$MultiUser.InstallMode"
		; if necessary, display text for different install mode than the actual one in $MultiUser.InstallMode
		!if ${MULTIUSER_INSTALLMODE_ALLOW_BOTH_INSTALLATIONS} == 0
			!if "${UNINSTALLER_FUNCPREFIX}" == ""
				${if} $MultiUser.InstallMode == "AllUsers" ; user selected "all users"
					${if} $HasPerMachineInstallation$HasPerUserInstallation == "01"
						StrCpy $0 "CurrentUser" ; display information for the "current user" installation
					${endif}
				${elseif} $HasPerMachineInstallation$HasPerUserInstallation == "10" ; user selected "current user"
					StrCpy $0 "AllUsers" ; display information for the "all users" installation
				${endif}
			!endif
		!endif

		; set label text
		StrCpy $2 ""
		${if} $0 == "AllUsers" ; all users
			${if} $HasPerMachineInstallation == 1
				!if "${UNINSTALLER_FUNCPREFIX}" == ""
					StrCpy $2 "Version $PerMachineInstallationVersion is already installed per-machine in $PerMachineInstallationFolder$\r$\n"
					${if} $PerMachineInstallationVersion == ${VERSION}
						StrCpy $2 "$2Will reinstall version ${VERSION}"
					${else}
						StrCpy $2 "$2Will uninstall version $PerMachineInstallationVersion and install version ${VERSION}"
					${endif}
					${if} $MultiUser.InstallMode == "AllUsers"
						StrCpy $2 "$2 per-machine"
					${else}
						StrCpy $2 "$2 per-user"
					${endif}
					StrCpy $2 "$2."
				!else
					StrCpy $2 "Version $PerMachineInstallationVersion is installed per-machine in $PerMachineInstallationFolder$\r$\nWill uninstall."
				!endif
			${else}
				StrCpy $2 "Fresh install for all users."
			${endif}
			${if} $IsAdmin == 0
				StrCpy $2 "$2 Will prompt for admin credentials."
			${endif}
		${else} ; current user
			${if} $HasPerUserInstallation == 1
				!if "${UNINSTALLER_FUNCPREFIX}" == ""
					StrCpy $2 "Version $PerUserInstallationVersion is already installed per-user in $PerUserInstallationFolder$\r$\n"
					${if} $PerUserInstallationVersion == ${VERSION}
						StrCpy $2 "$2Will reinstall version ${VERSION}"
					${else}
						StrCpy $2 "$2Will uninstall version $PerUserInstallationVersion and install version ${VERSION}"
					${endif}
					${if} $MultiUser.InstallMode == "AllUsers"
						StrCpy $2 "$2 per-machine"
					${else}
						StrCpy $2 "$2 per-user"
					${endif}
					StrCpy $2 "$2."
				!else
					StrCpy $2 "Version $PerUserInstallationVersion is installed per-user in $PerUserInstallationFolder$\r$\nWill uninstall."
				!endif
			${else}
				StrCpy $2 "Fresh install for current user only."
			${endif}
		${endif}
		SendMessage $MultiUser.InstallModePage.Description ${WM_SETTEXT} 0 "STR:$2"

		Pop $2
		Pop $1
		Pop $0
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionLabelClick
		Exch $0 ; get clicked control's HWND, which is on the stack in $0
		nsDialogs::GetUserData $0
		Pop $0

		${NSD_Uncheck} $MultiUser.InstallModePage.AllUsers
		${NSD_Uncheck} $MultiUser.InstallModePage.CurrentUser
		${NSD_Check} $0 ; ${NSD_Check} will check both radio buttons without the above 2 lines
		${NSD_SetFocus} $0
		Push $0
		; ${NSD_Check} doesn't call Click event
		Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionClick

		Pop $0
	FunctionEnd

	Function ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallModeOptionClick
		Exch $0 ; get clicked control's HWND, which is on the stack in $0

		; set InstallMode
		${if} $0 == $MultiUser.InstallModePage.AllUsers
			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.AllUsers
		${else}
			Call ${UNINSTALLER_FUNCPREFIX}MultiUser.InstallMode.CurrentUser
		${endif}

		Call ${UNINSTALLER_FUNCPREFIX}MultiUser.SetShieldAndTexts

		Pop $0
	FunctionEnd
!macroend

!macro MULTIUSER_GetCurrentUserString VAR
	StrCpy ${VAR} ""
	!if ${MULTIUSER_INSTALLMODE_ALLOW_BOTH_INSTALLATIONS} != 0
		${if} $MultiUser.InstallMode == "CurrentUser"
			StrCpy ${VAR} " (current user)"
		${endif}
	!endif
!macroend

!macro MULTIUSER_RegistryAddInstallInfo
	Push "$0"

	; Write the installation path into the registry
	WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY_PATH}" "${MULTIUSER_INSTALLMODE_INSTDIR_REGISTRY_VALUENAME}" "$INSTDIR" ; "InstallLocation"

	; Write the uninstall keys for Windows
	; Workaround for Windows issue: if the uninstall key names are the same in HKLM and HKCU, Windows displays only one entry in the add/remove programs dialog;
	; this will create 2 different keys in HKCU (MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY_PATH and MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH),
	; but that's OK, both will be removed by uninstaller
	!insertmacro MULTIUSER_GetCurrentUserString $0

	${if} $MultiUser.InstallMode == "AllUsers" ; setting defaults
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "DisplayName" "${MULTIUSER_INSTALLMODE_DISPLAYNAME}"
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "UninstallString" '"$INSTDIR\${UNINSTALL_FILENAME}" /allusers'
	${else}
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "DisplayName" "${MULTIUSER_INSTALLMODE_DISPLAYNAME} (current user)" ; "add/remove programs" will show if installation is per-user
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "UninstallString" '"$INSTDIR\${UNINSTALL_FILENAME}" /currentuser'
	${endif}

	WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "DisplayVersion" "${VERSION}"
	WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "DisplayIcon" "$INSTDIR\${PROGEXE},0"
	!ifdef PUBLISHER_NAME
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "Publisher" "${PUBLISHER_NAME}"
	!else
		!ifdef COMPANY_NAME
			WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "Publisher" "${COMPANY_NAME}"
		!endif
	!endif
	!ifdef COMPANY_URL
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "URLInfoAbout" "${COMPANY_URL}"
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "URLUpdateInfo" "${COMPANY_URL}"
	!endif
        !ifdef SUPPORT
                WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "HelpLink" "${SUPPORT}"
	!endif
	!ifdef COMMENTS
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "Comments" "${COMMENTS}"
	!endif
	!ifdef VERSION_MAJOR
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "VersionMajor" "${VERSION_MAJOR}"
	!endif
	!ifdef VERSION_MINOR
		WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "VersionMinor" "${VERSION_MINOR}"
	!endif
	WriteRegDWORD SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "InstallDate" "${NOW}"
	WriteRegDWORD SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "NoModify" 1
	WriteRegDWORD SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "NoRepair" 1

	; Write InstallDate string value in 'YYYYMMDD' format.
	; Without it, Windows gets the date from the registry key metadata, which might be inaccurate.
	System::Call /NOUNLOAD "*(&i2,&i2,&i2,&i2,&i2,&i2,&i2,&i2) i .r4"
	System::Call /NOUNLOAD "kernel32::GetLocalTime(i)i(r4)"
	System::Call /NOUNLOAD "*$4(&i2,&i2,&i2,&i2,&i2,&i2,&i2,&i2)i(.r1,.r2,,.r3,,,,)"
	System::Free $4
	IntCmp $2 9 0 0 +2
	StrCpy $2 "0$2"
	IntCmp $3 9 0 0 +2
	StrCpy $3 "0$3"
	WriteRegStr SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "InstallDate" "$1$2$3"

	Pop $4
	Pop $3
	Pop $2
	Pop $1
	Pop $0
!macroend

!macro MULTIUSER_RegistryAddInstallSizeInfo
	Push "$0"
	Push "$1"
	Push "$2"
	Push "$3"
	Push "$4"
	Push "$5"
	Push "$6"
	Push "$7"

	!insertmacro MULTIUSER_GetCurrentUserString $0

	${GetSize} "$INSTDIR" "/S=0K" $2 $3 $4 ; get install folder size
	IntOp $1 $1 + $2
	!ifdef INSTDIR_AppDataProduct
		${GetSize} "$INSTDIR_AppDataProduct" "/S=0K" $5 $6 $7 ; get user data folder size
		IfErrors 0 +3
		DetailPrint "Warning - could not get size of ${INSTDIR_AppDataProduct}, using 50MB estimate."
		IntOp  $5 $5 + 50000 ; If error, set user data folder size to default value of 50MB
		IntOp $1 $1 + $5
	!else
	  DetailPrint "Error - could not get user data size, path not defined."
	!endif
	IntFmt $1 "0x%08X" $1 ; Convert to KB
	WriteRegDWORD SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0" "EstimatedSize" "$1"

	Pop $7
	Pop $6
	Pop $5
	Pop $4
	Pop $3
	Pop $2
	Pop $1
	Pop $0
!macroend

!macro MULTIUSER_RegistryRemoveInstallInfo
	Push $0

	; Remove registry keys
	DeleteRegKey SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}"
	!insertmacro MULTIUSER_GetCurrentUserString $0
	${if} "$0" != ""
		DeleteRegKey SHCTX "${MULTIUSER_INSTALLMODE_UNINSTALL_REGISTRY_KEY_PATH}$0"
	${endif}
	DeleteRegKey SHCTX "${MULTIUSER_INSTALLMODE_INSTALL_REGISTRY_KEY_PATH}"

	Pop $0
!macroend

!verbose pop
