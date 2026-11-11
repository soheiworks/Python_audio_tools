# Audio speed conversion x2.5
#
# 安全対策(壊れたファイルを作らないための仕組み):
#  1. 変換結果はまず「.part」という仮ファイルに書き、最後まで成功して再生チェックに合格したものだけ本来の名前にする
#  2. 前回までに残った壊れた出力は検出して削除し、元ファイルが「済」にあれば元の場所に戻して再変換する
#  3. ジョブの状態判定を修正(開始待ち=NotStarted を「終わった」と誤判定しない)
#  4. ffmpegに -nostdin / -y を付け、-loglevel を正しい位置(-i の前)に移動

$targetDir = $PSScriptRoot
$speed = 2.5
$bitrate = "48k"
$outputDir = Join-Path $targetDir "x${speed}"
$doneDir = Join-Path $targetDir "済"

$maxJobs = [Math]::Min([Environment]::ProcessorCount, 8)

$ffmpegPath = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ffmpegPath) { $ffmpegPath = "ffmpeg" }

if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory | Out-Null
}
if (-not (Test-Path -LiteralPath $doneDir)) {
    New-Item -Path $doneDir -ItemType Directory | Out-Null
}

Write-Host "Target : $targetDir" -ForegroundColor Cyan
Write-Host "Output : $outputDir" -ForegroundColor Cyan
Write-Host "Done   : $doneDir" -ForegroundColor Cyan
Write-Host "Speed  : ${speed}x" -ForegroundColor Cyan
Write-Host "Bitrate: $bitrate" -ForegroundColor Cyan
Write-Host "Jobs   : $maxJobs" -ForegroundColor Cyan
Write-Host ("-" * 50)

# 再生できるファイルか確認する(音声は作り直さず、先頭から末尾まで読めるかだけ見る)
function Test-AudioFile {
    param($ffmpegExe, $path)
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $err = & $ffmpegExe -nostdin -v error -i $path -c copy -f null - 2>&1
    return (($LASTEXITCODE -eq 0) -and (-not $err))
}

# --- 前回までに残った壊れたファイルの後始末 ---
Write-Host "Checking existing output files..." -ForegroundColor Cyan
foreach ($part in @(Get-ChildItem -LiteralPath $outputDir -Filter "*.part")) {
    Remove-Item -LiteralPath $part.FullName -Force
}
$suffix = "_x${speed}"
foreach ($out in @(Get-ChildItem -LiteralPath $outputDir -Filter "*.m4a")) {
    if (-not (Test-AudioFile $ffmpegPath $out.FullName)) {
        Write-Host "BROKEN (removed): $($out.Name)" -ForegroundColor Red
        Remove-Item -LiteralPath $out.FullName -Force
        $baseName = $out.BaseName
        if ($baseName.EndsWith($suffix)) {
            $baseName = $baseName.Substring(0, $baseName.Length - $suffix.Length)
        }
        $doneFile = Join-Path $doneDir "$baseName.m4a"
        if (Test-Path -LiteralPath $doneFile) {
            Move-Item -LiteralPath $doneFile -Destination (Join-Path $targetDir "$baseName.m4a") -Force
            Write-Host "  -> source moved back for re-conversion" -ForegroundColor DarkCyan
        } else {
            Write-Host "  -> source not found in done folder (re-download needed)" -ForegroundColor Yellow
        }
    }
}
Write-Host ("-" * 50)

$extensions = @("*.m4a")
$files = @()
foreach ($ext in $extensions) {
    $files += @(Get-ChildItem -LiteralPath $targetDir -Filter $ext)
}

if ($files.Count -eq 0) {
    Write-Host "No audio files found." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "Files found: $($files.Count)" -ForegroundColor Cyan
Write-Host ("-" * 50)

# 1ファイル分の変換(別プロセスで実行される)
$jobScript = {
    param($inputPath, $outputPath, $ffmpegExe, $speed, $bitrate)
    $partPath = "$outputPath.part"
    try {
        $err = & $ffmpegExe -nostdin -y -v error -i $inputPath -vn -filter:a "atempo=$speed" -c:a aac -b:a $bitrate -f ipod $partPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ Ok = $false; Message = "ffmpeg exit code ${LASTEXITCODE}: $err" }
        }
        $err = & $ffmpegExe -nostdin -v error -i $partPath -c copy -f null - 2>&1
        if (($LASTEXITCODE -ne 0) -or $err) {
            return [pscustomobject]@{ Ok = $false; Message = "output check failed: $err" }
        }
        Move-Item -LiteralPath $partPath -Destination $outputPath -Force
        return [pscustomobject]@{ Ok = $true; Message = "" }
    }
    finally {
        if (Test-Path -LiteralPath $partPath) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$jobs = [System.Collections.Generic.List[object]]::new()
$jobFileMap = @{}

function Collect-CompletedJobs {
    # 「Running 以外」ではなく「終了した状態」だけを対象にする
    $completed = @($jobs | Where-Object { $_.State -in @('Completed', 'Failed', 'Stopped') })
    foreach ($job in $completed) {
        $result = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | Select-Object -Last 1
        $info = $jobFileMap[$job.Id]
        if ($result -and $result.Ok) {
            Write-Host "OK: $(Split-Path $info.Output -Leaf)" -ForegroundColor Green
            $dest = Join-Path $info.DoneDir (Split-Path $info.Input -Leaf)
            Move-Item -LiteralPath $info.Input -Destination $dest -Force
            Write-Host "  -> moved to done folder" -ForegroundColor DarkCyan
        } else {
            Write-Host "ERROR: $(Split-Path $info.Input -Leaf)" -ForegroundColor Red
            if ($result) {
                Write-Host "  $($result.Message)" -ForegroundColor DarkRed
            } elseif ($job.ChildJobs.Count -gt 0 -and $job.ChildJobs[0].JobStateInfo.Reason) {
                Write-Host "  $($job.ChildJobs[0].JobStateInfo.Reason.Message)" -ForegroundColor DarkRed
            }
        }
        Remove-Job -Job $job -Force
        $jobs.Remove($job) | Out-Null
    }
}

foreach ($file in $files) {
    $inputPath  = $file.FullName
    $outputPath = Join-Path $outputDir "$($file.BaseName)_x${speed}$($file.Extension)"

    # 上のチェックで壊れた出力は削除済みなので、ここで存在するものは正常なファイル
    if (Test-Path -LiteralPath $outputPath) {
        Write-Host "SKIP (exists): $($file.Name)" -ForegroundColor Yellow
        continue
    }

    Write-Host "Queued: $($file.Name)" -ForegroundColor White

    # 開始待ち(NotStarted)も「動いているジョブ」として数える
    while (@($jobs | Where-Object { $_.State -in @('NotStarted', 'Running') }).Count -ge $maxJobs) {
        Start-Sleep -Milliseconds 300
        Collect-CompletedJobs
    }

    $job = Start-Job -ScriptBlock $jobScript -ArgumentList $inputPath, $outputPath, $ffmpegPath, $speed, $bitrate
    $jobFileMap[$job.Id] = @{ Input = $inputPath; Output = $outputPath; DoneDir = $doneDir }
    $jobs.Add($job)
}

Write-Host ("-" * 50)
Write-Host "Waiting for remaining jobs..." -ForegroundColor Cyan

while ($jobs.Count -gt 0) {
    Start-Sleep -Milliseconds 300
    Collect-CompletedJobs
}

Write-Host ""
Write-Host ("=" * 50)
Write-Host "Done." -ForegroundColor Green
Read-Host "Press Enter to exit"
