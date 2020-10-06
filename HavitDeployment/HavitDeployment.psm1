
Import-Module (Join-Path $PSScriptRoot -ChildPath HavitMerge.psm1)
Import-Module (Join-Path $PSScriptRoot -ChildPath HavitMergeVariables.psm1)
Import-Module (Join-Path $PSScriptRoot -ChildPath HavitCoreDeployment.psm1)
Import-Module (Join-Path $PSScriptRoot -ChildPath HavitAzureDeployment.psm1)

# HavitMerge.psm1

Export-ModuleMember -Function Remove-JsonComments
Export-ModuleMember -Function Merge-JsonFileToJsonFile
Export-ModuleMember -Function Merge-JsonFiles
Export-ModuleMember -Function Merge-JsonFileToJsonZipFile
Export-ModuleMember -Function Merge-ConfigurationJsonFilesToZipFileAutomatically

# HavitMergeVariables.psm1
Export-ModuleMember -Function Merge-AdosVariablesToJsonZipFile
Export-ModuleMember -Function Merge-AdosVariablesToJsonZipFileAutomatically
Export-ModuleMember -Function Merge-AzureKeyVaultSecretsToJsonZipFile
Export-ModuleMember -Function Save-AdosVariablesToSetParametersFile

# HavitCoreDeployment.psm1

Export-ModuleMember -Function Confirm-HavitDeployment
Export-ModuleMember -Function Find-HavitPackage
Export-ModuleMember -Function Backup-HavitWebsiteToPackage
Export-ModuleMember -Function Publish-HavitWebsitePackage
Export-ModuleMember -Function Publish-HavitWebsiteAppOfflineFile
Export-ModuleMember -Function Remove-HavitWebsiteAppOfflineFile
Export-ModuleMember -Function Publish-HavitWebsitePackageWithAppOfflineFile

# HavitAzureDeployment.psm1

Export-ModuleMember -Function Get-HavitAzureWebApp
Export-ModuleMember -Function Get-HavitAzureWebAppPublishingInfo
Export-ModuleMember -Function Backup-HavitAzureWebsiteToPackage
Export-ModuleMember -Function Publish-HavitAzureWebsitePackage
#Export-ModuleMember -Function Publish-HavitWebsiteAppOfflineFile
#Export-ModuleMember -Function Remove-HavitWebsiteAppOfflineFile
Export-ModuleMember -Function Publish-HavitAzureWebsitePackageWithAppOfflineFile
Export-ModuleMember -Function Reset-HavitAzureWebAppPublishingInfo
