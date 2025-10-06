param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)] [string] $Command,
        [string[]] $Arguments = @(),
        [string] $ErrorMessage = "Command failed"
    )

    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "${ErrorMessage}. Exit code: $exitCode"
    }
}

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$TerraformDir = Join-Path $ProjectRoot 'terraform'

function Get-TerraformOutput {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [switch] $AllowEmpty
    )

    $tfArgs = @("-chdir=$TerraformDir", "output", "-no-color", "-raw", $Name)
    $value = & terraform @tfArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Failed to read Terraform output '$Name'. Exit code: $exitCode"
    }

    $trimmed = $value.Trim()
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Terraform output '$Name' is empty. Run 'terraform apply' and try again."
    }
    if ($trimmed.StartsWith('Warning:')) {
        throw "Terraform output '$Name' returned a warning. Run 'terraform apply' and ensure outputs exist."
    }

    return $trimmed
}

Push-Location $ProjectRoot
try {
    Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

    # 1. Build Lambda package
    Write-Host "Building Lambda package..." -ForegroundColor Yellow
    Push-Location 'backend'
    try {
        Invoke-ExternalCommand -Command 'uv' -Arguments @('run', 'deploy.py') -ErrorMessage 'Failed to build Lambda package'
    }
    finally {
        Pop-Location
    }

    # 2. Terraform workspace & apply
    Push-Location 'terraform'
    try {
        Invoke-ExternalCommand -Command 'terraform' -Arguments @('init', '-input=false') -ErrorMessage 'Terraform init failed'

        $workspaceList = & terraform workspace list -no-color
        $workspaceExitCode = $LASTEXITCODE
        if ($workspaceExitCode -ne 0) {
            throw "Failed to list Terraform workspaces. Exit code: $workspaceExitCode"
        }

        $workspaceNames = @()
        foreach ($item in $workspaceList) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $workspaceNames += $item.Trim().TrimStart('*').Trim()
            }
        }

        if ($workspaceNames -contains $Environment) {
            Invoke-ExternalCommand -Command 'terraform' -Arguments @('workspace', 'select', $Environment) -ErrorMessage "Failed to select Terraform workspace '$Environment'"
        }
        else {
            Invoke-ExternalCommand -Command 'terraform' -Arguments @('workspace', 'new', $Environment) -ErrorMessage "Failed to create Terraform workspace '$Environment'"
        }

        if ($Environment -eq 'prod') {
            Invoke-ExternalCommand -Command 'terraform' -Arguments @(
                'apply',
                '-var-file=prod.tfvars',
                "-var=project_name=$ProjectName",
                "-var=environment=$Environment",
                '-auto-approve'
            ) -ErrorMessage 'Terraform apply failed'
        }
        else {
            Invoke-ExternalCommand -Command 'terraform' -Arguments @(
                'apply',
                "-var=project_name=$ProjectName",
                "-var=environment=$Environment",
                '-auto-approve'
            ) -ErrorMessage 'Terraform apply failed'
        }
    }
    finally {
        Pop-Location
    }

    $ApiUrl = Get-TerraformOutput -Name 'api_gateway_url'
    $FrontendBucket = Get-TerraformOutput -Name 's3_frontend_bucket'
    try {
        $CustomUrl = Get-TerraformOutput -Name 'custom_domain_url' -AllowEmpty
    }
    catch {
        $CustomUrl = ''
    }

    # 3. Build + deploy frontend
    Push-Location 'frontend'
    try {
        Write-Host "Setting API URL for production..." -ForegroundColor Yellow
        "NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File -FilePath '.env.production' -Encoding utf8

        Invoke-ExternalCommand -Command 'npm' -Arguments @('install') -ErrorMessage 'npm install failed'
        Invoke-ExternalCommand -Command 'npm' -Arguments @('run', 'build') -ErrorMessage 'npm run build failed'
        Invoke-ExternalCommand -Command 'aws' -Arguments @('s3', 'sync', '.\out', "s3://$FrontendBucket/", '--delete') -ErrorMessage 'aws s3 sync failed'
    }
    finally {
        Pop-Location
    }

    # 4. Final summary
    $CfUrl = Get-TerraformOutput -Name 'cloudfront_url'
    Write-Host "Deployment complete!" -ForegroundColor Green
    Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($CustomUrl)) {
        Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
    }
    Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
}
finally {
    Pop-Location
}


