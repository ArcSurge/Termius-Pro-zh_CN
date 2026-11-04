@echo off
rem THIS FILE MUST STAY PURE ASCII.
rem cmd.exe parses a whole batch file with the code page active at startup, so
rem non-ASCII text here would be decoded as GBK and can corrupt the parser.
rem
rem Bypass cmd's "Terminate batch job (Y/N)?" prompt on Ctrl+C: re-run this
rem script with stdin redirected from NUL. When cmd later tries to ask Y/N it
rem reads EOF and terminates immediately instead of waiting for an answer.
rem
rem Two quirks of "CALL <NUL %0" re-entry, both verified on this machine:
rem   1. %~dp0 no longer points at this file's folder after re-entry, so the
rem      script path is passed through TERMIUS_ZH_* environment variables.
rem   2. Variables set inside a parenthesized block are expanded at parse time,
rem      so the logic below uses goto instead of big if/else blocks.
rem
rem cmd's stdin stays NUL so its Y/N prompt reads EOF and disappears.
rem PowerShell's stdin is explicitly reconnected to the console with <CON,
rem allowing Console.ReadKey / Read-Host to wait for a real key at the end.
setlocal

rem Save the own path first: the argument loop below shifts away %0.
set "SELF=%~f0"

if "%~1"=="-FIXED_CTRL_C" goto :reentry

rem ---- first entry: locate script, parse arguments -------------------------

set "SCRIPT=%~dp0Update-TermiusZh-windows.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: Update-TermiusZh-windows.ps1 was not found next to this file.
    exit /b 1
)

set "MODE=-Apply"
set "FLAVOR="
set "PACKAGE="
:parse
if "%~1"=="" goto :launch
if /i "%~1"=="-check"  set "MODE=-CheckOnly"
if /i "%~1"=="--check" set "MODE=-CheckOnly"
if /i "%~1"=="-trial"  set "FLAVOR=-Flavor trial"
if /i "%~1"=="-skip"   set "FLAVOR=-Flavor skip"
rem -Package takes a value: l/t/k shorthand, e.g. "-package ltk" for trial+skip.
if /i "%~1"=="-package"  goto :package
if /i "%~1"=="--package" goto :package
rem Also accept the joined forms -package=ltk / --package=ltk.
rem "-package=" is 9 chars, "--package=" is 10 chars: the value starts right after.
set "JOINED=%~1"
if /i "%JOINED:~0,9%"=="-package=" goto :packagejoined1
if /i "%JOINED:~0,10%"=="--package=" goto :packagejoined2
set "JOINED="
shift
goto :parse

:package
shift
if "%~1"=="" (
    echo ERROR: -package needs a value, for example: -package ltk
    exit /b 1
)
set "PACKAGE=-Package %~1"
shift
goto :parse

:packagejoined1
set "PACKAGE=-Package %JOINED:~9%"
set "JOINED="
shift
goto :parse

:packagejoined2
set "PACKAGE=-Package %JOINED:~10%"
set "JOINED="
shift
goto :parse

:launch
set "TERMIUS_ZH_SCRIPT=%SCRIPT%"
set "TERMIUS_ZH_MODE=%MODE%"
set "TERMIUS_ZH_FLAVOR=%FLAVOR%"
set "TERMIUS_ZH_PACKAGE=%PACKAGE%"
rem <NUL is the whole trick: cmd's Y/N prompt reads EOF and exits silently.
CALL <NUL "%SELF%" -FIXED_CTRL_C
GOTO :EOF

rem ---- re-entry with stdin from NUL ----------------------------------------

:reentry
set "SCRIPT=%TERMIUS_ZH_SCRIPT%"
set "MODE=%TERMIUS_ZH_MODE%"
set "FLAVOR=%TERMIUS_ZH_FLAVOR%"
set "PACKAGE=%TERMIUS_ZH_PACKAGE%"

chcp 65001 >nul

rem The window stays open because the PowerShell script itself waits for a key
rem (Console.ReadKey) before exiting. No cmd "pause" here: it cannot work with
rem stdin redirected from NUL.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %MODE% %FLAVOR% %PACKAGE% <CON
exit /b %errorlevel%
