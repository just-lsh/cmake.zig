@echo off
rem Downloads the ZLS release in .\version into this directory (Windows).
rem On Linux and macOS use download.sh.
rem
rem To update ZLS:
rem   1. Write the new release, for example 0.17.0, into .\version. Pick the one that
rem      matches the Zig release in ..\version.
rem   2. Copy the SHA-256 checksums of its archives (the "shasum" fields in
rem      https://builds.zigtools.org/index.json) into .\checksums.txt,
rem      one "<arch>-<os> <sha256>" line per platform.
rem   3. Run this script.
setlocal
cd /d "%~dp0"

set ZLS_ARCH=
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set ZLS_ARCH=x86_64
if "%PROCESSOR_ARCHITECTURE%"=="ARM64" set ZLS_ARCH=aarch64
if not defined ZLS_ARCH (
    echo Unsupported architecture: %PROCESSOR_ARCHITECTURE%
    exit /b 1
)

set ZLS_SHA256=
for /f %%v in (version) do set ZLS_VERSION=%%v
for /f "tokens=1,2" %%a in (checksums.txt) do if "%%a"=="%ZLS_ARCH%-windows" set ZLS_SHA256=%%b
set ZLS_NAME=zls-%ZLS_ARCH%-windows-%ZLS_VERSION%
set ZLS_ARCHIVE=cache\%ZLS_NAME%.zip
set ZLS_URL=https://builds.zigtools.org/%ZLS_NAME%.zip

if not defined ZLS_SHA256 (
    echo No checksum for %ZLS_ARCH%-windows in checksums.txt.
    exit /b 1
)

set ZLS_INSTALLED=
if exist zls.exe for /f %%v in ('zls.exe version') do set ZLS_INSTALLED=%%v
if "%ZLS_INSTALLED%"=="%ZLS_VERSION%" (
    echo ZLS %ZLS_VERSION% is already installed.
    exit /b 0
)

rem The archive is kept in .\cache, so CI can cache that directory.
if not exist cache mkdir cache
if not exist "%ZLS_ARCHIVE%" (
    echo Downloading %ZLS_URL% ...
    curl.exe --fail --location --retry 3 --silent --show-error --output "%ZLS_ARCHIVE%.part" "%ZLS_URL%" || exit /b 1
    move /y "%ZLS_ARCHIVE%.part" "%ZLS_ARCHIVE%" >nul || exit /b 1
)

certutil -hashfile "%ZLS_ARCHIVE%" SHA256 | findstr /i /x "%ZLS_SHA256%" >nul
if errorlevel 1 (
    del "%ZLS_ARCHIVE%"
    echo Checksum mismatch for %ZLS_URL%, expected %ZLS_SHA256%.
    exit /b 1
)

rem The archive holds its files at the top level. Only the binary is installed.
rem Windows' own tar.exe can read zip files, a GNU tar earlier in PATH (e.g. from Git) can't.
echo Extracting %ZLS_ARCHIVE% ...
if exist zls.exe del zls.exe
"%SystemRoot%\System32\tar.exe" -xf "%ZLS_ARCHIVE%" zls.exe || exit /b 1

echo Installed ZLS %ZLS_VERSION% to %CD%\zls.exe
