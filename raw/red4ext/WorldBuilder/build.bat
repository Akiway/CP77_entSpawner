@echo off
REM Builds WorldBuilderTools.dll and deploys it into ..\..\..\resources\red4ext\plugins\.
REM Uses the CMake and Ninja that ship with VS Build Tools, so nothing extra needs installing.
setlocal

set "SCRIPT_DIR=%~dp0"

REM Probe the usual VS 2022 layouts. Add a path here if yours differs.
set "VSPATH="
if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools"
if not defined VSPATH if exist "%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools"
if not defined VSPATH if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%ProgramFiles%\Microsoft Visual Studio\2022\Community"
if not defined VSPATH if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%ProgramFiles%\Microsoft Visual Studio\2022\Professional"
if not defined VSPATH if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise"

if not defined VSPATH (
    echo ERROR: no Visual Studio 2022 install with the C++ toolset was found.
    exit /b 1
)

echo Using Visual Studio at: %VSPATH%

REM vcvars64 is what puts the CRT headers (cstddef and friends) on INCLUDE.
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo ERROR: vcvars64.bat failed.
    exit /b 1
)

set "CMAKE=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "NINJA=%VSPATH%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"

if not exist "%CMAKE%" (
    echo ERROR: cmake.exe not found at "%CMAKE%".
    exit /b 1
)

"%CMAKE%" -S "%SCRIPT_DIR%." -B "%SCRIPT_DIR%build" -G Ninja -DCMAKE_MAKE_PROGRAM="%NINJA%" -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 exit /b 1

"%CMAKE%" --build "%SCRIPT_DIR%build"
if errorlevel 1 exit /b 1

echo.
echo Built and deployed to source\resources\red4ext\plugins\WorldBuilder\WorldBuilderTools.dll
endlocal
