param([string]$Flutter = 'flutter')
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$applicationRoot = Join-Path $projectRoot 'app'
$fixturePath = Join-Path $applicationRoot 'test/readme_preview_render_temp_test.dart'
if (Test-Path -LiteralPath $fixturePath) {
    throw "Temporary fixture already exists: $fixturePath"
}
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'render_previews.dart') -Destination $fixturePath
    Push-Location -LiteralPath $applicationRoot
    try {
        & $Flutter test test/readme_preview_render_temp_test.dart --no-pub --update-goldens --reporter expanded
        if ($LASTEXITCODE -ne 0) { throw "Preview rendering failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
} finally {
    if (Test-Path -LiteralPath $fixturePath) {
        Remove-Item -LiteralPath $fixturePath
    }
}
