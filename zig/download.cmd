@echo off
rem Downloads the Zig release in .\version into this directory (Windows).
rem On Linux and macOS use download.sh.
rem
rem Usage: zig\download.cmd [mirror]
rem
rem   mirror  Optional Zig community mirror to download from instead of ziglang.org,
rem           for example https://pkg.hexops.org/zig (no trailing slash).
rem           See https://ziglang.org/download/community-mirrors/.
rem
rem To update Zig:
rem   1. Write the new release, for example 0.17.1, into .\version.
rem   2. Copy the SHA-256 checksums of its archives from https://ziglang.org/download/
rem      (or the "shasum" fields in https://ziglang.org/download/index.json) into
rem      .\checksums.txt, one "<arch>-<os> <sha256>" line per platform.
rem   3. Update ZLS to a matching release, see zls\download.cmd.
rem   4. Run this script.
setlocal
cd /d "%~dp0"

set ZIG_ARCH=
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set ZIG_ARCH=x86_64
if "%PROCESSOR_ARCHITECTURE%"=="ARM64" set ZIG_ARCH=aarch64
if not defined ZIG_ARCH (
    echo Unsupported architecture: %PROCESSOR_ARCHITECTURE%
    exit /b 1
)

set ZIG_SHA256=
for /f %%v in (version) do set ZIG_VERSION=%%v
for /f "tokens=1,2" %%a in (checksums.txt) do if "%%a"=="%ZIG_ARCH%-windows" set ZIG_SHA256=%%b
set ZIG_NAME=zig-%ZIG_ARCH%-windows-%ZIG_VERSION%
set ZIG_ARCHIVE=cache\%ZIG_NAME%.zip
rem ziglang.org keeps releases in a directory per version, mirrors serve them flat.
set ZIG_URL=https://ziglang.org/download/%ZIG_VERSION%/%ZIG_NAME%.zip
if not "%~1"=="" set ZIG_URL=%~1/%ZIG_NAME%.zip

if not defined ZIG_SHA256 (
    echo No checksum for %ZIG_ARCH%-windows in checksums.txt.
    exit /b 1
)

set ZIG_INSTALLED=
if exist zig.exe for /f %%v in ('zig.exe version') do set ZIG_INSTALLED=%%v
if "%ZIG_INSTALLED%"=="%ZIG_VERSION%" (
    echo Zig %ZIG_VERSION% is already installed.
    exit /b 0
)

rem The archive is kept in .\cache, so CI can cache that directory.
if not exist cache mkdir cache
if not exist "%ZIG_ARCHIVE%" (
    echo Downloading %ZIG_URL% ...
    curl.exe --fail --location --retry 3 --silent --show-error --output "%ZIG_ARCHIVE%.part" "%ZIG_URL%" || exit /b 1
    move /y "%ZIG_ARCHIVE%.part" "%ZIG_ARCHIVE%" >nul || exit /b 1
)

certutil -hashfile "%ZIG_ARCHIVE%" SHA256 | findstr /i /x "%ZIG_SHA256%" >nul
if errorlevel 1 (
    del "%ZIG_ARCHIVE%"
    echo Checksum mismatch for %ZIG_URL%, expected %ZIG_SHA256%.
    exit /b 1
)

rem Windows' own tar.exe can read zip files, a GNU tar earlier in PATH (e.g. from Git) can't.
echo Extracting %ZIG_ARCHIVE% ...
if exist zig.exe del zig.exe
if exist lib rmdir /s /q lib
if exist doc rmdir /s /q doc
"%SystemRoot%\System32\tar.exe" -xf "%ZIG_ARCHIVE%" --strip-components=1 || exit /b 1

echo Installed Zig %ZIG_VERSION% to %CD%\zig.exe
