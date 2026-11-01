# Audio speed conversion x2.25

$targetDir = $PSScriptRoot
$speed = 2.25
$bitrate = "48k"
$outputDir = Join-Path $targetDir "x${speed}"
$doneDir = Join-Path $targetDir "済"

$maxJobs = [Math]::Min([Environment]::ProcessorCount, 8)

$ffmpegPath = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ffmpegPath) { $ffmpegPath = "ffmpeg" }

if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory | Out-Null
}
if (-not (Test-Path $doneDir)) {
    New-Item -Path $doneDir -ItemType Directory | Out-Null
}

Write-Host "Target : $targetDir" -ForegroundColor Cyan
Write-Host "Output : $outputDir" -ForegroundColor Cyan
Write-Host "Done   : $doneDir" -ForegroundColor Cyan
Write-Host "Speed  : ${speed}x" -ForegroundColor Cyan
Write-Host "Bitrate: $bitrate" -ForegroundColor Cyan
Write-Host "Jobs   : $maxJobs" -ForegroundColor Cyan
Write-Host ("-" * 50)

$extensions = @("*.m4a")
$files = @()
foreach ($ext in $extensions) {
    $files += @(Get-ChildItem -Path $targetDir -Filter $ext)
}

if ($files.Count -eq 0) {
    Write-Host "No audio files found." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "Files found: $($files.Count)" -ForegroundColor Cyan
Write-Host ("-" * 50)

$jobScript = {
    param($inputPath, $outputPath, $ffmpegExe, $speed, $bitrate)
    & $ffmpegExe -i $inputPath -filter:a "atempo=$speed" -c:a aac -b:a $bitrate $outputPath -loglevel error 2>&1 | Out-Null
    return $LASTEXITCODE
}

$jobs = [System.Collections.Generic.List[object]]::new()
$jobFileMap = @{}

function Collect-CompletedJobs {
    $completed = @($jobs | Where-Object { $_.State -ne 'Running' })
    foreach ($job in $completed) {
        $exitCode = Receive-Job -Job $job
        $info = $jobFileMap[$job.Id]
        if ($exitCode -eq 0) {
            Write-Host "OK: $(Split-Path $info.Output -Leaf)" -ForegroundColor Green
            $dest = Join-Path $info.DoneDir (Split-Path $info.Input -Leaf)
            Move-Item -Path $info.Input -Destination $dest -Force
            Write-Host "  -> moved to done folder" -ForegroundColor DarkCyan
        } else {
            Write-Host "ERROR: $(Split-Path $info.Input -Leaf)" -ForegroundColor Red
        }
        Remove-Job -Job $job
        $jobs.Remove($job) | Out-Null
    }
}

foreach ($file in $files) {
    $input  = $file.FullName
    $output = Join-Path $outputDir "$($file.BaseName)_x${speed}$($file.Extension)"

    if (Test-Path $output) {
        Write-Host "SKIP (exists): $($file.Name)" -ForegroundColor Yellow
        continue
    }

    Write-Host "Queued: $($file.Name)" -ForegroundColor White

    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $maxJobs) {
        Start-Sleep -Milliseconds 300
        Collect-CompletedJobs
    }

    $job = Start-Job -ScriptBlock $jobScript -ArgumentList $input, $output, $ffmpegPath, $speed, $bitrate
    $jobFileMap[$job.Id] = @{ Input = $input; Output = $output; DoneDir = $doneDir }
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
