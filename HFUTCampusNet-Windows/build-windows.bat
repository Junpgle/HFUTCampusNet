@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ============================================================================
echo   HFUTCampusNet for Windows (合肥工业大学校园网与智慧校园助手) 一键构建脚本
echo ============================================================================

cd /d "%~dp0"

where dotnet >nul 2>nul
if %errorlevel% neq 0 (
    echo [错误] 未检测到 .NET SDK，请先安装 .NET 8.0 SDK: https://dotnet.microsoft.com/download/dotnet/8.0
    pause
    exit /b 1
)

echo.
echo [1/3] 正在编译轻量级单文件版 (Framework-Dependent, 需系统含 .NET 8 Desktop Runtime)...
dotnet publish HFUTCampusNet.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o publish\win-x64-lightweight
if %errorlevel% neq 0 (
    echo [错误] 轻量级单文件版构建失败！
    pause
    exit /b 1
)

echo.
echo [2/3] 正在编译独立运行单文件版 (Self-Contained, 免安装 .NET 运行时，开箱即用)...
dotnet publish HFUTCampusNet.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o publish\win-x64-standalone
if %errorlevel% neq 0 (
    echo [错误] 独立运行单文件版构建失败！
    pause
    exit /b 1
)

echo.
echo [3/3] 正在打包发布压缩包 HFUTCampusNet-Windows-x64.zip...
if exist "publish\release_pkg" rmdir /s /q "publish\release_pkg"
mkdir "publish\release_pkg"
copy /y "publish\win-x64-standalone\HFUTCampusNet.exe" "publish\release_pkg\HFUTCampusNet.exe" >nul
copy /y "publish\win-x64-lightweight\HFUTCampusNet.exe" "publish\release_pkg\HFUTCampusNet-Lightweight.exe" >nul

powershell -NoProfile -Command "Compress-Archive -Path 'publish\release_pkg\*' -DestinationPath 'HFUTCampusNet-Windows-x64.zip' -Force"

echo.
echo ============================================================================
echo [完成] 构建成功！生成文件如下：
echo   1. 独立免安装单文件版: %~dp0publish\win-x64-standalone\HFUTCampusNet.exe
echo   2. 轻量框架依赖单文件: %~dp0publish\win-x64-lightweight\HFUTCampusNet.exe
echo   3. 完整发布压缩包    : %~dp0HFUTCampusNet-Windows-x64.zip
echo ============================================================================
if "%CI%"=="" pause
