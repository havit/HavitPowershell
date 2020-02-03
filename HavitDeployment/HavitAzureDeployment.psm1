#Add-Type -Path 'C:\Program Files (x86)\Microsoft SDKs\Azure\PowerShell\ResourceManager\AzureResourceManager\AzureRM.Websites\Microsoft.Azure.Management.Websites.dll'

class HavitAzurePublishingInfo
{
    [string] $PublishUrl
    [string] $Username
    [string] $Password    
    [string] $WebsiteName
}

function Get-HavitAzureWebApp {
    param(
        [string] $SubscriptionName,
        [string] $WebAppName,
        [string] $Slot = $null
    )
    
    Write-Host Reading web app information... -ForegroundColor Yellow

    $oldProgressPreference = $progressPreference
    $progressPreference = 'silentlyContinue' 

    $azureContext = Set-AzureRmContext -SubscriptionName $SubscriptionName
    if ($azureContext -eq $null)
    {
        throw "Subscription name $SubscriptionName not found."
    }

    $webapps = Get-AzureRMWebApp -Name $WebAppName
    
    if ($webapps.Count -eq 0)
    {
        throw "Web application $WebAppName not found."
    }

    $progressPreference = $oldProgressPreference

    if (-Not ([string]::IsNullOrEmpty($Slot)))
    {
        $slots = Get-AzureRMWebAppSlot -WebApp $webapps[0] -Slot $Slot

        if ($slots.Count -eq 0)
        {
            throw "Slot $Slot not found for web application $WebAppName."
        }
        return $slots[0]
    }
    else
    {
        return $webapps[0]
    }
}

function Get-HavitAzureWebAppPublishingInfo {
    param(
        [Microsoft.Azure.Management.WebSites.Models.Site] $WebApp
    )

    $tempFileName = [System.IO.Path]::GetTempFileName()
    Get-AzureRMWebAppPublishingProfile -WebApp $WebApp -OutputFile $tempFileName | out-null
    [xml] $publishingProfileXml = Get-Content $tempFileName
    Remove-Item $tempFileName

    $publishingInfo = $publishingProfileXml.PublishData.PublishProfile | Where-Object { $_.publishMethod -eq "MsDeploy" } | Select-Object -Property publishUrl, msdeploySite, userName, userPWD -First 1
   
    $result = [HavitAzurePublishingInfo]::new()
    $result.PublishUrl = ('https://' + $publishingInfo.PublishUrl + '/MsDeploy.axd')
    $result.Username = $publishingInfo.userName
    $result.Password = $publishingInfo.userPWD
    $result.WebsiteName = $publishingInfo.msdeploySite

	return $result
}

function Publish-HavitAzureWebsitePackage {
    param(
        [Microsoft.Azure.Management.WebSites.Models.Site] $WebApp = $null,
        [HavitAzurePublishingInfo] $PublishInfo = $null,
        [string] $WdpFile = $null,
        [string] $DeploySetParametersFile = $null,
        [object[]] $CustomMsDeployArguments = $null
    )

    if (($PublishInfo -eq $null) -And ($WebApp -eq $null))
    {
        throw "PublishInfo or WebApp must be set."
    }

    if ($PublishInfo -eq $null)
    {
        $PublishInfo = Get-HavitAzureWebAppPublishingInfo -WebApp $WebApp
    }
	Publish-HavitWebsitePackage -Url $PublishInfo.PublishUrl -Username $PublishInfo.Username -Password $PublishInfo.Password -WebsiteName $PublishInfo.WebsiteName -WdpFile $WdpFile -DeploySetParametersFile $DeploySetParametersFile -CustomMsDeployArguments $CustomMsDeployArguments
}

function Publish-HavitAzureWebsitePackageWithAppOfflineFile {
    param (
        [Microsoft.Azure.Management.WebSites.Models.Site] $WebApp = $null,
        [HavitAzurePublishingInfo] $PublishInfo = $null,        
        [string] $AppOfflineFile = "app_offline.htm",
        [string] $WdpFile = $null,
        [string] $DeploySetParametersFile,
        [object[]] $CustomMsDeployArguments = $null,
        [bool] $NoWait = $false
    )

    if (($PublishInfo -eq $null) -And ($WebApp -eq $null))
    {
        throw "PublishInfo or WebApp must be set."
    }

    if ($PublishInfo -eq $null)
    {
        $PublishInfo = Get-HavitAzureWebAppPublishingInfo -WebApp $WebApp
    }
    Publish-HavitWebsitePackageWithAppOfflineFile -Url $PublishInfo.PublishUrl -Username $PublishInfo.Username -Password $PublishInfo.Password -WebsiteName $PublishInfo.WebsiteName -AppOfflineFile $AppOfflineFile -WdpFile $WdpFile -DeploySetParametersFile $DeploySetParametersFile -CustomMsDeployArguments $CustomMsDeployArguments -NoWait $NoWait
}

function Backup-HavitAzureWebsiteToPackage {
    param (
        [Microsoft.Azure.Management.WebSites.Models.Site] $WebApp = $null,
        [HavitAzurePublishingInfo] $PublishInfo = $null,
        [string] $BackupLocation,
        [string] $BackupFilenameSegment,
        [object[]] $CustomMsDeployArguments = $null
    )

    if (($PublishInfo -eq $null) -And ($WebApp -eq $null))
    {
        throw "PublishInfo or WebApp must be set."
    }

    if ($PublishInfo -eq $null)
    {
        $PublishInfo = Get-HavitAzureWebAppPublishingInfo -WebApp $WebApp
    }
    Backup-HavitWebsiteToPackage -Url $PublishInfo.PublishUrl -Username $PublishInfo.Username -Password $PublishInfo.Password -WebsiteName $PublishInfo.WebsiteName -BackupLocation $BackupLocation -BackupFilenameSegment $BackupFilenameSegment -CustomMsDeployArguments $CustomMsDeployArguments
}

function Reset-HavitAzureWebAppPublishingInfo {
    param (
        [Microsoft.Azure.Management.WebSites.Models.Site] $WebApp
    )    
    Reset-AzureRMWebAppPublishingProfile -WebApp $WebApp | Out-Null
}

Export-ModuleMember -Function Get-HavitAzureWebApp
Export-ModuleMember -Function Get-HavitAzureWebAppPublishingInfo
Export-ModuleMember -Function Backup-HavitAzureWebsiteToPackage
Export-ModuleMember -Function Publish-HavitAzureWebsitePackage
#Export-ModuleMember -Function Publish-HavitWebsiteAppOfflineFile
#Export-ModuleMember -Function Remove-HavitWebsiteAppOfflineFile
Export-ModuleMember -Function Publish-HavitAzureWebsitePackageWithAppOfflineFile
Export-ModuleMember -Function Reset-HavitAzureWebAppPublishingInfo