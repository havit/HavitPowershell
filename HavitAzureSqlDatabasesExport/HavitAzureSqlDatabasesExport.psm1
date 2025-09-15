
Import-Module (Join-Path $PSScriptRoot -ChildPath HavitAzureSqlDatabasesExportCore.psm1)

# HavitAzureSqlDatabasesExportCore.psm1
Export-ModuleMember -Function Export-AzureSqlDatabases
