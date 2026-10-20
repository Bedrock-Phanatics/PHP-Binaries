$ErrorActionPreference="Stop"
$ProgressPreference="SilentlyContinue"

$versions = @{}
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'versions.env') | ForEach-Object {
    if ($_ -notmatch '^([A-Z0-9_]+)=([A-Za-z0-9_.-]+)$') { throw "Invalid versions.env entry: $_" }
    $versions[$Matches[1]] = $Matches[2]
}
$PHP_SDK_VER=$versions.PHP_SDK_VERSION
$ARCH="x64"
$LIBYAML_VER=$versions.YAML_VERSION
$PTHREAD_W32_VER=$versions.PTHREADS4W_VERSION
$LEVELDB_MCPE_VER=$versions.LEVELDB_VERSION
$LIBDEFLATE_VER=$versions.LIBDEFLATE_VERSION
$PHP_QTHREADS_COMMIT=$versions.EXT_QTHREADS_COMMIT
$PHP_YAML_VER=$versions.EXT_YAML_VERSION
$PHP_CHUNKUTILS2_VER=$versions.EXT_CHUNKUTILS2_VERSION
$PHP_IGBINARY_VER=$versions.EXT_IGBINARY_VERSION
$PHP_LEVELDB_VER=$versions.EXT_LEVELDB_VERSION
$PHP_CRYPTO_VER=$versions.EXT_CRYPTO_VERSION
$PHP_RECURSIONGUARD_VER=$versions.EXT_RECURSIONGUARD_VERSION
$PHP_MORTON_VER=$versions.EXT_MORTON_VERSION
$PHP_LIBDEFLATE_VER=$versions.EXT_LIBDEFLATE_VERSION
$PHP_XXHASH_VER=$versions.EXT_XXHASH_VERSION
$PHP_XDEBUG_VER=$versions.EXT_XDEBUG_VERSION
$PHP_ARRAYDEBUG_VER=$versions.EXT_ARRAYDEBUG_VERSION
$PHP_ENCODING_VER=$versions.EXT_ENCODING_VERSION
$PHP_SNAPPY_VER=$versions.EXT_SNAPPY_VERSION
$PHP_SNAPPY_COMMIT=$versions.EXT_SNAPPY_COMMIT
$PHP_TOML_VER=$versions.EXT_TOML_VERSION
$PHP_TOML_COMMIT=$versions.EXT_TOML_COMMIT
$checksums = @{}
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sources.sha256') | ForEach-Object {
    if ($_ -notmatch '^([0-9a-f]{64})  (\S+)$') { throw "Invalid sources.sha256 entry: $_" }
    $checksums[$Matches[2]] = $Matches[1]
}
$windowsDeps = @()
$windowsDepsLock = Join-Path $PSScriptRoot 'windows-deps.sha256'
Get-Content -LiteralPath $windowsDepsLock | ForEach-Object {
    if ($_ -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9_.-]+\.zip)$') { throw "Invalid windows-deps.sha256 entry: $_" }
    $windowsDeps += $Matches[2]
    $checksums["php-deps-$($Matches[2])"] = $Matches[1]
}
$windowsDepsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $windowsDepsLock).Hash


function pm-echo {
    param ([string] $message)

    echo "[PocketMine] $message"
    echo "[PocketMine] $message" >> "$log_file"
}

function pm-echo-error {
    param ([string] $message)

    pm-echo "[ERROR] $message"
}

function pm-fatal-error {
    param ([string] $message)

    pm-echo-error $message
    exit 1
}

$library = ""
$library_version = ""
function write-library {
    param ([string] $library, [string] $version)

    Write-Host -NoNewline "[$library $version]"
    $script:library = $library
    $script:library_version = $version
}
function write-status {
    param ([string] $status)

    Write-Host -NoNewline " $status..."
    echo "[$library $library_version] $status..." >> $log_file
}
function write-download {
    write-status "downloading"
}
function write-extracting {
    write-status "extracting"
}
function write-configure {
    write-status "configuring"
}
function write-compile {
    write-status "compiling"
}
function write-install {
    write-status "installing"
}
function write-done {
    echo " done!"
    $script:library = ""
    $script:library_version = ""
}
function write-cached {
    write-status "using cache"
}

$log_file="$pwd\compile.log"
echo "" > "$log_file"
$outpath="$pwd"

pm-echo "PHP compiler for Windows"
date >> "$log_file"

pm-echo "Checking dependencies"

$script_dependencies = @("git", "cmake")
foreach ($dep in $script_dependencies) {
    $depInfo = Get-Command "$dep" -ErrorAction SilentlyContinue
    if ($depInfo -eq $null) {
        pm-fatal-error "$dep is required but can't be found in your PATH"
    } else {
        pm-echo "Found $dep in $($depInfo.Source)"
    }
}



pm-echo "Checking configuration options"

$PHP_VERSION_BASE="auto"
if ($env:PHP_VERSION_BASE -ne $null) {
    $PHP_VERSION_BASE=$env:PHP_VERSION_BASE
}

$PHP_DEBUG_BUILD=0
if ($env:PHP_DEBUG_BUILD -eq 1) {
	$PHP_DEBUG_BUILD=1
}

$MSBUILD_CONFIGURATION="RelWithDebInfo"

if ($PHP_DEBUG_BUILD -eq 0) {
    $OUT_PATH_REL="Release"
    $PHP_HAVE_DEBUG="enable-debug-pack"
    pm-echo "Building release binaries with debugging symbols"
} else {
    $OUT_PATH_REL="Debug"
    $PHP_HAVE_DEBUG="enable-debug"

    #I don't like this, but YAML will crash if it's not built with the same target as PHP
    $MSBUILD_CONFIGURATION="Debug"
    pm-echo "Building debug binaries"
}


function php-version-id {
    param ([string] $version)

    $parts = $version.Split(".")

	#TODO: patch is a pain because of suffixes and we don't really need it anyway
    $result = (([int]$parts[0]) * 10000) + (([int]$parts[1]) * 100)
    return $result
}

$PREFERRED_PHP_VERSION_BASE=""
switch ($env:PM_VERSION_MAJOR) {
    5 { $PREFERRED_PHP_VERSION_BASE="8.4" }
    $null { pm-fatal-error "Please specify PocketMine-MP major version by setting the PM_VERSION_MAJOR environment variable" }
    default { pm-fatal-error "PocketMine-MP $PM_VERSION_MAJOR is not supported by this version of the build script" }
}

$PM_VERSION_MAJOR=$env:PM_VERSION_MAJOR
pm-echo "Compiling with configuration for PocketMine-MP $PM_VERSION_MAJOR"

if ($PHP_VERSION_BASE -eq "auto") {
    $PHP_VERSION_BASE=$PREFERRED_PHP_VERSION_BASE
} elseif ($PHP_VERSION_BASE -ne $PREFERRED_PHP_VERSION_BASE) {
    pm-fatal-error "Unsupported PHP base version $PHP_VERSION_BASE"
}

$PHP_VER=$versions.PHP_VERSION

#don't really need these except for dev versions
$PHP_GIT_REV="php-$PHP_VER"
$PHP_DISPLAY_VER="$PHP_VER"

$CMAKE_TARGET="Visual Studio 17 2022"

$PHP_VERSION_ID = php-version-id $PHP_VER
$VC_VER="vs17"
$SDK_TOOLSET_FLAG=""
$CMAKE_TOOLSET_FLAG=""

pm-echo "Selected PHP $PHP_VER ($PHP_VERSION_ID), SDK target $VC_VER ($SDK_TOOLSET_FLAG), CMake target $CMAKE_TARGET ($CMAKE_TOOLSET_FLAG)"

$PHP_JIT_ENABLE_ARG="yes"

if ($env:SOURCES_PATH -ne $null) {
    $BASE_PATH=$env:SOURCES_PATH
} else {
    $BASE_PATH="C:\pocketmine-php"
}
$PHP_SDK_PATH="$BASE_PATH\php-sdk-binary-tools-$PHP_SDK_VER"
$SOURCES_PATH="$BASE_PATH\php-$PHP_DISPLAY_VER-$($OUT_PATH_REL.ToLower())"
$LIB_BUILD_DIR="$BASE_PATH\deps-build-php-$PHP_VERSION_BASE-$($OUT_PATH_REL.ToLower())-$($windowsDepsHash.Substring(0,12))"
$DEPS_DIR="$BASE_PATH\deps-php-$PHP_VERSION_BASE-$($OUT_PATH_REL.ToLower())-$($windowsDepsHash.Substring(0,12))"
$basePathFull=[IO.Path]::GetFullPath($BASE_PATH).TrimEnd('\') + '\'
foreach ($path in @($SOURCES_PATH, $LIB_BUILD_DIR, $DEPS_DIR)) {
    if (![IO.Path]::GetFullPath($path).StartsWith($basePathFull, [StringComparison]::OrdinalIgnoreCase)) {
        pm-fatal-error "Build path is outside $BASE_PATH"
    }
}

pm-echo "Using path $SOURCES_PATH for PHP build sources"
if (-not (Test-Path "$BASE_PATH")) {
    mkdir "$BASE_PATH" >> $log_file 2>&1
}

if (Test-Path "$pwd\bin") {
    pm-echo "Deleting old binary folder..."
    Remove-Item -Recurse -Force "$pwd\bin" 2>&1
}
if (Test-Path $SOURCES_PATH) {
    pm-echo "Deleting old PHP build workspace $SOURCES_PATH..."
    Remove-Item -Recurse -Force $SOURCES_PATH 2>&1
}
$download_cache="$pwd\download_cache"
function download-file {
    param ([string] $url, [string] $prefix)

    $cached_filename="$prefix-$($url.Substring($url.LastIndexOf("/") + 1))"
    $cached_path="$download_cache\$cached_filename"
    $expected_hash=$checksums[$cached_filename]
    if (!$expected_hash) { pm-fatal-error "No SHA-256 pin for $cached_filename" }

    if (!(Test-Path $download_cache)) {
        mkdir $download_cache >> $log_file 2>&1
    }

    if (Test-Path $cached_path) {
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $cached_path).Hash -ne $expected_hash) {
            pm-echo-error "Discarding corrupt cached file $cached_filename"
            Remove-Item -LiteralPath $cached_path
        } else {
            echo "Cache hit for URL: $url" >> $log_file
        }
    }
    if (!(Test-Path $cached_path)) {
        echo "Downloading file from $url to $cached_path" >> $log_file
        $temp_path="$cached_path.$PID.tmp"
        try {
            Invoke-WebRequest -Uri $url -OutFile $temp_path >> $log_file 2>&1
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $temp_path).Hash -ne $expected_hash) {
                pm-fatal-error "SHA-256 mismatch for $cached_filename"
            }
            Move-Item -LiteralPath $temp_path -Destination $cached_path
        } finally {
            Remove-Item -LiteralPath $temp_path -ErrorAction SilentlyContinue
        }
    }

    return $cached_path
}

function unzip-file {
    param ([string] $file, [string] $destination)

    #expand-archive doesn't respect script-local ProgressPreference
    #https://github.com/PowerShell/Microsoft.PowerShell.Archive/issues/77
    $oldProgressPref = $global:ProgressPreference
    $global:ProgressPreference = "SilentlyContinue"
    Expand-Archive -Path $file -DestinationPath $destination >> $log_file 2>&1
    $global:ProgressPreference = $oldProgressPref
}


function append-file-utf8 {
    param ([string] $line, [string] $file)

    Out-File -Append -FilePath $file -Encoding utf8 -InputObject $line
}

function download-sdk {
    write-library "PHP SDK" $PHP_SDK_VER

    if (Test-Path "$PHP_SDK_PATH") {
        write-cached
    } else {
        write-download
        $file = download-file "https://github.com/php/php-sdk-binary-tools/archive/refs/tags/php-sdk-$PHP_SDK_VER.zip" "php-sdk"
        write-extracting
        unzip-file $file $pwd
        Move-Item "php-sdk-binary-tools-php-sdk-$PHP_SDK_VER" $PHP_SDK_PATH
    }
    write-done
}

function sdk-command {
    param ([string] $command, [string] $errorMessage = "")

    New-Item task.bat -Value $command >> $log_file 2>&1
    echo "Running SDK command: $command" >> $log_file
    $wrap = "`"$PHP_SDK_PATH\phpsdk-starter.bat`" -c $VC_VER -a $ARCH $SDK_TOOLSET_FLAG -t task.bat 2>&1"
    echo "SDK wrapper command: $wrap" >> $log_file
    (& cmd.exe /c $wrap) >> $log_file
    $result=$LASTEXITCODE
    if ($result -ne 0) {
        if ($errorMessage -eq "") {
            pm-fatal-error "Error code $result running SDK build command"
        } else {
            pm-fatal-error $errorMessage
        }
    }
    Remove-Item task.bat
}

function download-php-deps {
    write-library "PHP prebuilt deps" "$PHP_VERSION_BASE/$VC_VER/$ARCH"
    $stamp="$DEPS_DIR\.quark-deps.sha256"
    if ((Test-Path $stamp) -and ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $windowsDepsHash)) {
        write-cached
        write-done
        return
    }
    if (Test-Path $DEPS_DIR) {
        Remove-Item -LiteralPath $DEPS_DIR -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DEPS_DIR | Out-Null
    foreach ($name in $windowsDeps) {
        $file = download-file "https://downloads.php.net/~windows/php-sdk/deps/$VC_VER/$ARCH/$name" "php-deps"
        Expand-Archive -LiteralPath $file -DestinationPath $DEPS_DIR -Force >> $log_file 2>&1
    }
    if (Test-Path "$DEPS_DIR\openssl.cnf") {
        New-Item -ItemType Directory -Force -Path "$DEPS_DIR\template\ssl" | Out-Null
        Move-Item -LiteralPath "$DEPS_DIR\openssl.cnf" -Destination "$DEPS_DIR\template\ssl\openssl.cnf" -Force
    }
    Set-Content -LiteralPath $stamp -Value $windowsDepsHash -NoNewline
    write-done
}

function build-yaml {
    write-library "yaml" $LIBYAML_VER
    write-download
    $file = download-file "https://github.com/yaml/libyaml/archive/$LIBYAML_VER.zip" "yaml"
    write-extracting
    unzip-file $file $pwd
    Move-Item "libyaml-$LIBYAML_VER" libyaml >> $log_file 2>&1
    Push-Location libyaml

    write-configure
    sdk-command "cmake -G `"$CMAKE_TARGET`" $CMAKE_TOOLSET_FLAG^`
        -DCMAKE_PREFIX_PATH=`"$DEPS_DIR`"^`
        -DCMAKE_INSTALL_PREFIX=`"$DEPS_DIR`"^`
        -DBUILD_SHARED_LIBS=ON^`
        `"$pwd`" || exit 1"
    write-compile
    sdk-command "msbuild ALL_BUILD.vcxproj /p:Configuration=$MSBUILD_CONFIGURATION /m || exit 1"
    write-install
    sdk-command "msbuild INSTALL.vcxproj /p:Configuration=$MSBUILD_CONFIGURATION /m || exit 1"
    Copy-Item "$MSBUILD_CONFIGURATION\yaml.pdb" "$DEPS_DIR\bin" >> $log_file 2>&1
    write-done
    Pop-Location
}

function build-pthreads4w {
    write-library "pthreads4w" $PTHREAD_W32_VER
    write-download
    $file = download-file "https://github.com/pmmp/DependencyMirror/releases/download/mirror/pthreads4w-code-v$PTHREAD_W32_VER.zip" "pthreads4w"
    write-extracting
    unzip-file $file $pwd
    Move-Item "pthreads4w-code-*" pthreads4w >> $log_file 2>&1
    Push-Location pthreads4w

    write-compile
    sdk-command "nmake VC || exit 1"

    write-install
    Copy-Item "pthread.h" "$DEPS_DIR\include" >> $log_file 2>&1
    Copy-Item "sched.h" "$DEPS_DIR\include" >> $log_file 2>&1
    Copy-Item "semaphore.h" "$DEPS_DIR\include" >> $log_file 2>&1
    Copy-Item "_ptw32.h" "$DEPS_DIR\include" >> $log_file 2>&1
    Copy-Item "pthreadVC3.lib" "$DEPS_DIR\lib" >> $log_file 2>&1
    Copy-Item "pthreadVC3.dll" "$DEPS_DIR\bin" >> $log_file 2>&1
    Copy-Item "pthreadVC3.pdb" "$DEPS_DIR\bin" >> $log_file 2>&1
    write-done
    Pop-Location
}

function build-leveldb {
    write-library "leveldb" $LEVELDB_MCPE_VER
    write-download
    $file = download-file "https://github.com/pmmp/leveldb/archive/$LEVELDB_MCPE_VER.zip" "leveldb"
    write-extracting
    unzip-file $file $pwd
    Move-Item leveldb-* leveldb >> $log_file 2>&1
    Push-Location leveldb

    write-configure
    sdk-command "cmake -G `"$CMAKE_TARGET`" $CMAKE_TOOLSET_FLAG^`
        -DCMAKE_PREFIX_PATH=`"$DEPS_DIR`"^`
        -DCMAKE_INSTALL_PREFIX=`"$DEPS_DIR`"^`
        -DBUILD_SHARED_LIBS=ON^`
        -DLEVELDB_BUILD_BENCHMARKS=OFF^`
        -DLEVELDB_BUILD_TESTS=OFF^`
        -DZLIB_LIBRARY=`"$DEPS_DIR\lib\zlib_a.lib`"^`
        `"$pwd`" || exit 1"

    write-compile
    sdk-command "msbuild ALL_BUILD.vcxproj /p:Configuration=$MSBUILD_CONFIGURATION /m || exit 1"
    write-install
    sdk-command "msbuild INSTALL.vcxproj /p:Configuration=$MSBUILD_CONFIGURATION /m || exit 1"
    Copy-Item "$MSBUILD_CONFIGURATION\leveldb.pdb" "$DEPS_DIR\bin" >> $log_file 2>&1
    write-done
    Pop-Location
}

function build-libdeflate {
    write-library "libdeflate" $LIBDEFLATE_VER
    write-download
    $file = download-file "https://github.com/ebiggers/libdeflate/archive/$LIBDEFLATE_VER.zip" "libdeflate"
    write-extracting
    unzip-file $file $pwd
    Move-Item libdeflate-* libdeflate >> $log_file 2>&1
    Push-Location libdeflate

    write-configure
    #TODO: not sure why we have arch here but not on other cmake targets
    sdk-command "cmake -G `"$CMAKE_TARGET`" -A `"$ARCH`" $CMAKE_TOOLSET_FLAG^`
        -DCMAKE_PREFIX_PATH=`"$DEPS_DIR`"^`
        -DCMAKE_INSTALL_PREFIX=`"$DEPS_DIR`"^`
        -DLIBDEFLATE_BUILD_GZIP=OFF^`
        -DLIBDEFLATE_BUILD_SHARED_LIB=ON^`
        -DLIBDEFLATE_BUILD_STATIC_LIB=OFF^`
        `"$pwd`" || exit 1"
    write-compile
    sdk-command "msbuild ALL_BUILD.vcxproj /p:Configuration=$MSBUILD_CONFIGURATION /m || exit 1"
    write-install
    sdk-command "msbuild INSTALL.vcxproj /p:Configuration=$MSBUILD_CONFIGURATION /m || exit 1"
    Copy-Item "$MSBUILD_CONFIGURATION\deflate.pdb" "$DEPS_DIR\bin" >> $log_file 2>&1
    write-done
    Pop-Location
}

function download-php {
    write-library "PHP" $PHP_VER
    write-download

    $file = download-file "https://github.com/php/php-src/archive/$PHP_GIT_REV.zip" "php"
    write-extracting
    unzip-file $file $pwd
    Move-Item "php-src-$PHP_GIT_REV" $SOURCES_PATH >> $log_file 2>&1
    write-done
}

function get-extension-zip {
    param ([string] $name, [string] $version, [string] $url, [string] $extractedName)

    write-library "php-ext $name" $version
    write-download
    $file = download-file $url "php-ext-$name"
    write-extracting
    unzip-file $file $pwd
    write-done
}

function get-github-extension {
    param ([string] $name, [string] $version, [string] $user, [string] $repo, [string] $versionPrefix)
    get-extension-zip $name $version "https://github.com/$user/$repo/archive/$versionPrefix$version.zip" "$repo-$version"
}

function download-php-extensions {
    Push-Location "$SOURCES_PATH\ext" >> $log_file 2>&1
    get-github-extension "pmmpthread" $PHP_QTHREADS_COMMIT "Bedrock-Phanatics" "ext-qthreads"
    get-github-extension "yaml"                  $PHP_YAML_VER                  "php"      "pecl-file_formats-yaml"
    get-github-extension "chunkutils2"           $PHP_CHUNKUTILS2_VER           "pmmp"     "ext-chunkutils2"
    get-github-extension "igbinary"              $PHP_IGBINARY_VER              "igbinary" "igbinary"
    get-github-extension "leveldb"               $PHP_LEVELDB_VER               "pmmp"     "php-leveldb"
    get-github-extension "recursionguard"        $PHP_RECURSIONGUARD_VER        "pmmp"     "ext-recursionguard"
    get-github-extension "morton"                $PHP_MORTON_VER                "pmmp"     "ext-morton"
    get-github-extension "libdeflate"            $PHP_LIBDEFLATE_VER            "pmmp"     "ext-libdeflate"
    get-github-extension "xxhash"                $PHP_XXHASH_VER                "pmmp"     "ext-xxhash"
    get-github-extension "xdebug"                $PHP_XDEBUG_VER                "xdebug"   "xdebug"
    get-github-extension "arraydebug"            $PHP_ARRAYDEBUG_VER            "pmmp"     "ext-arraydebug"
    get-github-extension "encoding"              $PHP_ENCODING_VER              "pmmp"     "ext-encoding"

    write-library "php-ext snappy" $PHP_SNAPPY_VER
    write-download
    (& cmd.exe /c "git clone --branch $PHP_SNAPPY_VER --depth 1 https://github.com/kjdev/php-ext-snappy.git snappy 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0 -or (& git -C snappy rev-parse HEAD) -ne $PHP_SNAPPY_COMMIT) { pm-fatal-error "Failed to verify ext-snappy source" }
    (& cmd.exe /c "git -C snappy submodule update --init --depth 1 snappy 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0) { pm-fatal-error "Failed to initialize ext-snappy submodule" }
    $snappy_config_path = "snappy\config.w32"
    $snappy_config = Get-Content $snappy_config_path -Raw
    $snappy_sources_directive = 'ADD_SOURCES("snappy",'
    if (!$snappy_config.Contains($snappy_sources_directive)) {
        pm-fatal-error "Unable to patch ext-snappy source paths in config.w32"
    }
    $snappy_config = $snappy_config.Replace($snappy_sources_directive, 'ADD_SOURCES(configure_module_dirname + "/snappy",')
    Set-Content -Path $snappy_config_path -Value $snappy_config -Encoding ascii
    $snappy_header = (Get-Content snappy\snappy\snappy-stubs-public.h.in -Raw).Replace('${HAVE_SYS_UIO_H_01}', '0').Replace('${PROJECT_VERSION_MAJOR}', '1').Replace('${PROJECT_VERSION_MINOR}', '2').Replace('${PROJECT_VERSION_PATCH}', '2')
    Set-Content -Path snappy\snappy\snappy-stubs-public.h -Value $snappy_header -Encoding ascii
    write-done

    write-library "php-ext crypto" $PHP_CRYPTO_VER
    write-download
    (& cmd.exe /c "git clone https://github.com/bukka/php-crypto.git crypto 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0) { pm-fatal-error "Failed to clone ext-crypto" }
    Push-Location crypto
    write-status "preparing"
    (& cmd.exe /c "git checkout $PHP_CRYPTO_VER 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0 -or (& git rev-parse HEAD) -ne $PHP_CRYPTO_VER) { pm-fatal-error "Failed to verify ext-crypto source" }
    (& cmd.exe /c "git submodule update --init --recursive 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0) { pm-fatal-error "Failed to initialize ext-crypto submodules" }
    write-done
    Pop-Location

    write-library "php-ext toml" $PHP_TOML_VER
    write-download
    (& cmd.exe /c "git clone https://github.com/TrixNEW/ext-toml.git toml 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0) { pm-fatal-error "Failed to clone ext-toml" }
    (& cmd.exe /c "git -C toml checkout $PHP_TOML_COMMIT 2>&1") >> $log_file
    if ($LASTEXITCODE -ne 0 -or (& git -C toml rev-parse HEAD) -ne $PHP_TOML_COMMIT) { pm-fatal-error "Failed to verify ext-toml source" }
    write-done

    Pop-Location
}

download-sdk

pm-echo "Checking that SDK can find Visual Studio"
#using CMAKE_TARGET for this is a bit meh but it's human readable at least
sdk-command "exit /b 0" "Please install $CMAKE_TARGET"

download-php-deps

$customStamp="$DEPS_DIR\.quark-custom-libs.stamp"
$customKey="{0}:{1}:{2}" -f (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash, (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot 'versions.env')).Hash, $windowsDepsHash
if ((Test-Path $customStamp) -and ((Get-Content -LiteralPath $customStamp -Raw).Trim() -eq $customKey)) {
    pm-echo "Using cached custom dependencies"
} else {
    if (Test-Path $LIB_BUILD_DIR) {
        Remove-Item -LiteralPath $LIB_BUILD_DIR -Recurse -Force
    }
    New-Item -ItemType Directory -Path $LIB_BUILD_DIR | Out-Null
    cd $LIB_BUILD_DIR >> $log_file 2>&1

    build-pthreads4w
    build-yaml
    build-leveldb
    build-libdeflate
    Set-Content -LiteralPath $customStamp -Value $customKey -NoNewline
}

cd $BASE_PATH >> $log_file 2>&1

download-php
download-php-extensions

cd "$SOURCES_PATH"
write-library "PHP" $PHP_VER
write-configure

sdk-command "buildconf.bat"
sdk-command "configure^`
    --with-mp=auto^`
    --with-prefix=pocketmine-php-bin^`
    --with-php-build=`"$DEPS_DIR`"^`
    --$PHP_HAVE_DEBUG^`
    --disable-all^`
    --disable-cgi^`
    --enable-cli^`
    --enable-zts^`
    --enable-pdo^`
    --enable-arraydebug=shared^`
    --enable-bcmath^`
    --enable-calendar^`
    --enable-chunkutils2=shared^`
    --enable-com-dotnet^`
    --enable-ctype^`
    --enable-encoding=shared^`
    --enable-fileinfo=shared^`
    --enable-filter^`
    --enable-hash^`
    --enable-igbinary=shared^`
    --enable-json^`
    --enable-mbstring^`
    --enable-morton^`
    --enable-opcache^`
    --enable-opcache-jit=$PHP_JIT_ENABLE_ARG^`
    --enable-phar^`
    --enable-recursionguard=shared^`
    --enable-sockets^`
    --enable-snappy=shared^`
    --enable-tokenizer^`
    --enable-toml^`
    --enable-xmlreader^`
    --enable-xmlwriter^`
    --enable-xxhash^`
    --enable-zip^`
    --enable-zlib^`
    --with-bz2=shared^`
    --with-crypto=shared^`
    --with-curl^`
    --with-dom^`
    --with-gd=shared^`
    --with-gmp^`
    --with-iconv^`
    --with-leveldb=shared^`
    --with-libdeflate=shared^`
    --with-libxml^`
    --with-mysqli=shared^`
    --with-mysqlnd^`
    --with-openssl^`
    --with-pcre-jit^`
    --with-pmmpthread=shared^`
    --with-pmmpthread-sockets^`
    --with-simplexml^`
    --with-sodium^`
    --with-sqlite3=shared^`
    --with-xdebug=shared^`
    --with-xdebug-compression^`
    --with-xml^`
    --with-yaml^`
    --with-pdo-mysql^`
    --with-pdo-sqlite^`
    --without-readline"

write-compile
sdk-command "nmake"

write-install
sdk-command "nmake snap"

#remove ICU DLLs copied unnecessarily by nmake snap - this needs to be removed if we ever have ext/intl as a dependency
Remove-Item "$SOURCES_PATH\$ARCH\$($OUT_PATH_REL)_TS\php-$PHP_DISPLAY_VER\icu*.dll" >> $log_file 2>&1
#remove enchant dependencies which are unnecessarily copied - this needs to be removed if we ever have ext/enchant as a dependency
Remove-Item "$SOURCES_PATH\$ARCH\$($OUT_PATH_REL)_TS\php-$PHP_DISPLAY_VER\glib-*.dll" >> $log_file 2>&1
Remove-Item "$SOURCES_PATH\$ARCH\$($OUT_PATH_REL)_TS\php-$PHP_DISPLAY_VER\gmodule-*.dll" >> $log_file 2>&1
Remove-Item -Recurse "$SOURCES_PATH\$ARCH\$($OUT_PATH_REL)_TS\php-$PHP_DISPLAY_VER\lib\enchant\" >> $log_file 2>&1

cd $outpath >> $log_file 2>&1
Move-Item -Force "$SOURCES_PATH\$ARCH\$($OUT_PATH_REL)_TS\php-debug-pack-*.zip" $outpath
Remove-Item -Recurse bin -ErrorAction Continue >> $log_file 2>&1
mkdir bin >> $log_file 2>&1
Move-Item "$SOURCES_PATH\$ARCH\$($OUT_PATH_REL)_TS\php-$PHP_DISPLAY_VER" bin\php

$php_exe = "$outpath\bin\php\php.exe"

if (!(Test-Path $php_exe)) {
    pm-fatal-error "Something has gone wrong. php.exe not found"
}
write-status "generating php.ini"

$php_ini="$outpath\bin\php\php.ini"

#all this work to make PS output utf-8/ascii instead of utf-16 :(
Out-File -FilePath $php_ini -Encoding ascii -InputObject ";Custom PocketMine-MP php.ini file"
append-file-utf8 "memory_limit=1024M" $php_ini
append-file-utf8 "display_errors=1" $php_ini
append-file-utf8 "display_startup_errors=1" $php_ini
append-file-utf8 "error_reporting=-1" $php_ini
append-file-utf8 "zend.assertions=-1" $php_ini
append-file-utf8 "extension_dir=ext" $php_ini
append-file-utf8 "extension=php_pmmpthread.dll" $php_ini
append-file-utf8 "extension=php_openssl.dll" $php_ini
append-file-utf8 "extension=php_chunkutils2.dll" $php_ini
append-file-utf8 "extension=php_igbinary.dll" $php_ini
append-file-utf8 "extension=php_leveldb.dll" $php_ini
append-file-utf8 "extension=php_crypto.dll" $php_ini
append-file-utf8 "extension=php_libdeflate.dll" $php_ini
append-file-utf8 "extension=php_encoding.dll" $php_ini
append-file-utf8 "extension=php_snappy.dll" $php_ini
append-file-utf8 "igbinary.compact_strings=0" $php_ini
append-file-utf8 "zend_extension=php_opcache.dll" $php_ini
append-file-utf8 "opcache.enable=1" $php_ini
append-file-utf8 "opcache.enable_cli=1" $php_ini
append-file-utf8 "opcache.save_comments=1" $php_ini
append-file-utf8 "opcache.validate_timestamps=1" $php_ini
append-file-utf8 "opcache.revalidate_freq=0" $php_ini
append-file-utf8 "opcache.file_update_protection=0" $php_ini
append-file-utf8 "opcache.cache_id=PHP_BINARY ;prevent sharing SHM between different binaries - they won't work because of ASLR" $php_ini
append-file-utf8 ";Optional extensions, supplied for plugin use" $php_ini
append-file-utf8 "extension=php_fileinfo.dll" $php_ini
append-file-utf8 "extension=php_gd.dll" $php_ini
append-file-utf8 "extension=php_mysqli.dll" $php_ini
append-file-utf8 "extension=php_sqlite3.dll" $php_ini
append-file-utf8 ";Optional extensions, supplied for debugging" $php_ini
append-file-utf8 "extension=php_recursionguard.dll" $php_ini
append-file-utf8 "recursionguard.enabled=0 ;disabled due to minor performance impact, only enable this if you need it for debugging" $php_ini
append-file-utf8 ";extension=php_arraydebug.dll" $php_ini
append-file-utf8 "" $php_ini
append-file-utf8 "opcache.jit=disable" $php_ini
append-file-utf8 "opcache.jit_buffer_size=0" $php_ini
append-file-utf8 ";zend_extension=php_xdebug.dll" $php_ini
append-file-utf8 ";https://xdebug.org/docs/all_settings#mode" $php_ini
append-file-utf8 "xdebug.mode=off" $php_ini
append-file-utf8 "xdebug.start_with_request=yes" $php_ini
append-file-utf8 ";The following overrides allow profiler, gc stats and traces to work correctly in ZTS" $php_ini
append-file-utf8 "xdebug.profiler_output_name=cachegrind.%s.%p.%r" $php_ini
append-file-utf8 "xdebug.gc_stats_output_name=gcstats.%s.%p.%r" $php_ini
append-file-utf8 "xdebug.trace_output_name=trace.%s.%p.%r" $php_ini
write-done
pm-echo "Xdebug is included, but disabled by default. To enable it, change 'xdebug.mode' in your php.ini file."

pm-echo "NOTE: You may need to install VC++ Redistributable for the binaries to work. Download it here: https://aka.ms/vs/17/release/vc_redist.x64.exe"
pm-echo "PHP binary files installed in $outpath\bin"
pm-echo "If the binary doesn't work, please report an issue at https://github.com/Bedrock-Phanatics/PHP-Binaries and attach the `"compile.log`" file"
