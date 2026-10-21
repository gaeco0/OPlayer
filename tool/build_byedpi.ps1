$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $projectRoot 'third_party/byedpi'
$ndkBin = 'D:/Apps/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin'
$targets = @{'arm64-v8a'='aarch64-linux-android24';'armeabi-v7a'='armv7a-linux-androideabi24';'x86_64'='x86_64-linux-android24'}
$sources = @('packets.c','main.c','conev.c','proxy.c','desync.c','mpool.c','extend.c') | ForEach-Object { Join-Path $sourceDir $_ }
foreach ($abi in $targets.Keys) {
    $outputDir = Join-Path $projectRoot "android/app/src/main/jniLibs/$abi"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $compiler = Join-Path $ndkBin ($targets[$abi] + '-clang.cmd')
    & $compiler -D_DEFAULT_SOURCE -std=c99 -O2 -fPIE -pie '-Wl,-z,max-page-size=16384' "-I$sourceDir" @sources -o (Join-Path $outputDir 'libciadpi.so')
    if ($LASTEXITCODE -ne 0) { throw "ByeDPI build failed: $abi" }
}
Write-Output 'Built ByeDPI v0.17.3 for Android arm64-v8a, armeabi-v7a and x86_64'
