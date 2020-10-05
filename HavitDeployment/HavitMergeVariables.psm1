function Get-AdosCustomVariables
{
    param(
        [string] $Prefix
    )

    $result = @();

    Write-Host "Reading and parsing public VSTS variables..."

    $variablesNamesSerialized = $env:VSTS_PUBLIC_VARIABLES
    
    if (![String]::IsNullOrWhiteSpace($variablesNamesSerialized))
    {    
        $variablesNames = $variablesNamesSerialized | ConvertFrom-Json
    
        #remove VSTS system values
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("agent.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("release.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("build.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("system.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("System.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("task.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_.StartsWith("system.")) }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "requestedForId") }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "DownloadBuildArtifacts.BuildNumber") }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "GIT_TERMINAL_PROMPT") }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "system") }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "VSTS_PROCESS_LOOKUP_ID") }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "MSDEPLOY_HTTP_USER_AGENT") }
        $variablesNames = $variablesNames | Where-Object { -not ($_ -eq "AZURE_HTTP_USER_AGENT") }

        if ($Prefix -ne $null)
        {
            Write-Host "Filtering public variables using a prefix..."

            $variablesNames = $variablesNames | Where-Object { $_.StartsWith($Prefix) } | ForEach-Object { $_.Substring($Prefix.Length) }
        }

        # convert list of variables to key-value pairs (variables and values)
        foreach ($variableName in $variablesNames)
        {
            $result += [pscustomobject]@{ Key = $variableName; Value = (Get-Item "env:$variableName" -ErrorAction SilentlyContinue).Value }
        }
    }

    Write-Host "$($result.Length) items found."

    # check no secret variables (with the prefix) is used
    Write-Host "Verifying secret VSTS variables..."
    $secretVariablesNamesSerialized = $env:VSTS_SECRET_VARIABLES
    if (![String]::IsNullOrWhiteSpace($secretVariablesNamesSerialized))
    {    
        $secretVariablesNames = $secretVariablesNamesSerialized | ConvertFrom-Json
        if ($Prefix -ne $null)
        {
            Write-Host "Filtering secret variables using a prefix..."

            $secretVariablesNames = $secretVariablesNames | Where-Object { $_.StartsWith($Prefix) } | ForEach-Object { $_.Substring($Prefix.Length) }

            if ($secretVariablesNames.Length -gt 0)
            {
                throw "Secret variables are not supported."
            }
        }
    }

    return ,$result # comma ensures NOT unwrapping single-item arrays (otherwise array is returned but the unwrapped single item is consumed)
}

function Get-AzureKeyVaultSecrets
{
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyVaultName,

        [Parameter(Mandatory = $true)]
        [string] $Prefix
    )

    $result = @();

    Write-Host "Reading variable list from Azure KeyVault..."
    $keyVaultSecrets = Get-AzKeyVaultSecret -VaultName $KeyVaultName
    
    #enabled keys only
    $keyVaultSecrets = $keyVaultSecrets | Where-Object { $_.Enabled }

    $keyVaultSecretNames = $keyVaultSecrets| ForEach-Object { $_.Name }

    foreach ($secretName in $keyVaultSecretNames)
    {
        if (($Prefix -eq $null) -or ($secretName.StartsWith($Prefix)))
        {
            $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName
            $secretValue = $secret.SecretValue | ConvertFrom-SecureString -AsPlainText
            # replace:
            # -- to -
            # - to .
            # (but no -- to ..!)
            # there cannot be dots in the secret name so we can do chained replacement (-- > .. > -)
            $key = $secretName
            if ($Prefix -ne $null)
            {
                $key = $key.Substring($Prefix.Length)
            }
            $key = $key.Replace("-", ".").Replace("..", "-");
            
            $result += [pscustomobject]@{ Key = $key; Value = $secretValue }
        }
    }

    return ,$result # comma ensures NOT unwrapping single-item arrays (otherwise array is returned but the unwrapped single item is consumed)
}

function Convert-VariablesToObject
{
    param($Variables)

    #converts key-value pairs to object    
    $root = New-Object -TypeName PsCustomObject

    foreach ($variableKeyValue in $Variables)
    {
        $propertySegments = $variableKeyValue.Key.Split('.')

        $property = $root

        foreach ($propertySegment in ($propertySegments | Select-Object -First ($propertySegments.Length - 1)))
        {
            $member = $property | Get-Member -Name $propertySegment -MemberType NoteProperty
            if ($member -eq $null)
            {        
                $property | Add-Member -MemberType NoteProperty -Name $propertySegment -Value (New-Object -TypeName PsCustomObject)
            }
            $property = $property.$($propertySegment)
        }

        $property | Add-Member -MemberType NoteProperty -Name $propertySegments[$propertySegments.Length - 1] -Value $variableKeyValue.Value
    }

    return $root
}

function Merge-KeyValueVariablesToJsonZipFile
{
    param (
        [Parameter(Mandatory = $true)]
        $Variables,

        [Parameter(Mandatory = $true)]
        [String] $TargetZipPath,

        [Parameter(Mandatory = $true)]
        [String] $ZipFile
    )

    $variablesAsObject = Convert-VariablesToObject -Variables $Variables

    Write-Host "Saving variables to a JSON file..."
    $variablesJsonTempFile = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()
    $variablesAsObject | ConvertTo-Json -Depth 20 | Out-File $variablesJsonTempFile
    
    Merge-JsonFileToJsonZipFile -DiffJsonPath $variablesJsonTempFile -TargetZipPath $TargetZipPath -ZipFile $ZipFile

    Write-Host "Removing temporary variables JSON file..."
    Remove-Item $variablesJsonTempFile
}

<#
.SYNOPSIS
Merges ADOS public variables to a target json file in a zip archive (can be also a web deploy package).

.DESCRIPTION
Merges ADOS public variables to a target json file in a zip archive (can be also a web deploy package).
All public ADOS variables must be in the base json file. Otherwise exception is thrown.
Only public ADOS variables are supported. When any secret variables is found, exception is thrown.
Json comments are removed (comments are not compatible with Powershell 5.x).
Json formatting is ugly.

.PARAMETER AdosVariablePrefix
Prefix of the ADOS variables to be used. Prefix is removed from the variable names.

.PARAMETER TargetZipPath
The zip file which containing a base json into which ADOS variables are merged.

.PARAMETER TargetJsonPath
Target json file in the zip path into which ADOS variables are merged.
Can NOT contain path, must be just a file name.
Can be located at any folder in the archive. Be careful with webjob parametrization.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.
#>
function Merge-AdosVariablesToJsonZipFile
{
    param (
        [String] $AdosVariablePrefix,

        [Parameter(Mandatory = $true)]
        [String] $TargetZipPath,

        [Parameter(Mandatory = $true)]
        [String] $ZipFile
    )

    $publicAdosVariables = Get-AdosCustomVariables
    Merge-KeyValueVariablesToJsonZipFile -Variables $publicAdosVariables -TargetZipPath $TargetZipPath -ZipFile $ZipFile
}

<#
.SYNOPSIS
Merges Azure KeyVault secrets to a target json file in a zip archive (can be also a web deploy package).

.DESCRIPTION
Merges Azure KeyVault secrets to a target json file in a zip archive (can be also a web deploy package).
All Azure KeyVault secrets variables must be in the base json file. Otherwise exception is thrown.
KeyVaultSecret names convention: Use a dash (-) as a substitition for dot (.), use double dashes (--) as a substitution for a single dash (-).
Json comments are removed (comments are not compatible with Powershell 5.x).
Json formatting is ugly.

.PARAMETER AdosVariablePrefix
Prefix of the ADOS variables to be used. Prefix is removed from the variable names.

.PARAMETER TargetZipPath
The zip file which containing a base json into which ADOS variables are merged.

.PARAMETER TargetJsonPath
Target json file in the zip path into which ADOS variables are merged.
Can NOT contain path, must be just a file name.
Can be located at any folder in the archive. Be careful with webjob parametrization.

.INPUTS
None. This function does not take input from the pipeline.

.OUTPUTS
None.
#>
function Merge-AzureKeyVaultSecretsToJsonZipFile
{
    param (
        [Parameter(Mandatory = $true)]
        [String] $KeyVaultName,

        [String] $KeyVaultSecretNamePrefix,

        [Parameter(Mandatory = $true)]
        [String] $TargetZipPath,

        [Parameter(Mandatory = $true)]
        [String] $ZipFile
    )

    $keyVaultVariables = Get-AzureKeyVaultSecrets -KeyVaultName $KeyVaultName -Prefix $KeyVaultSecretNamePrefix
    Merge-KeyValueVariablesToJsonZipFile -Variables $keyVaultVariables -TargetZipPath $TargetZipPath -ZipFile $ZipFile
}
