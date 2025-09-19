function Export-AzureSqlDatabases
{
    param($DbServerName,
        $DbServerResourceGroupName,
        $DbServerResourceIdForPrivateLink,
        $DbServerAdministratorUsername,
        [SecureString] $DbServerAdministratorPassword,
        $StorageAccountName,
        $StorageContainerName,
        $StorageKey,
        $StorageResourceIdForPrivateLink
    )

    # PREPARE storageUri
    $storageUri = "https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/" # musí končit limítkem

    #REMOVE PREVIOUS BLOBS

    Write-Host 'Retrieving storage account...'
    # using storage key - does not need "access to subscription"
    $storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageKey

    Write-Host "Deleting blobs previously exported from $DbServerName..."
    # deleting only files with dbServerName prefix (upper case)
    Get-AzStorageBlob -Container $StorageContainerName -Context $storageCtx -Prefix $DbServerName.ToUpper() | Remove-AzStorageBlob

    #LIST (AND FILTER) DATABASES (from the current subscription)

    Write-Host "Listing databases..."
    $allDatabases = Get-AzSqlDatabase -ServerName $DbServerName.ToLower() -ResourceGroupName $DbServerResourceGroupName    
    $databases = $allDatabases | Where-Object { $_.Edition -ne "System" } | Where-Object { $_.Edition -ne "None" } | Sort-Object -Property DatabaseName

    #EXPORT DATABASES
    $exportFailed = $false
    
    foreach ($database in $databases)
    {           
        if ($database.DatabaseName -match '_d{4}-\d{2}-\d{2}T\d{2}-\d{2}Z$')
        {
            Write-Host "Skipping export $($database.DatabaseName) database."
        }

        #using dbServerName as prefix (upper case) (to distinquish database sources and to be able to clear only database exports in storage)
        $bacpacName = $DbServerName.ToUpper() + '-' + $database.DatabaseName + '.bacpac'
        $storageBlobUri = $StorageUri + $bacpacName
    
        Write-Host "Starting export $($database.DatabaseName) database to $bacpacName..."
        
        $PSPersistPreference = $True

        $exportRequestParams = @{
            ResourceGroupName                   = $DbServerResourceGroupName
            ServerName                          = $DbServerName.ToLower()
            DatabaseName                        = $database.DatabaseName
            StorageKeyType                      = "StorageAccessKey"
            StorageKey                          = $StorageKey
            StorageUri                          = $storageBlobUri
            UseNetworkIsolation                 = $true
            AdministratorLogin                  = $DbServerAdministratorUsername
            AdministratorLoginPassword          = $DbServerAdministratorPassword
            StorageAccountResourceIdForPrivateLink = $StorageResourceIdForPrivateLink
            SqlServerResourceIdForPrivateLink   = $DbServerResourceIdForPrivateLink
        }

        $exportRequest = New-AzSqlDatabaseExport @exportRequestParams

        if (-not $exportRequest)
        {
            Write-Warning "Failed."
            Write-Host "Waiting 120 seconds..."
            Start-Sleep -Second 120

            Write-Host "Starting export $($database.DatabaseName) database to $bacpacName..."
            $exportRequest = New-AzSqlDatabaseExport @exportRequestParams
        }
        
        $PSPersistPreference = $false

        if ($exportRequest)
        {
            Write-Host "Started export $($database.DatabaseName) database to $($exportRequest.StorageUri)."
            
            # PRIVATE LINK ACCEPTANCE
            if ($dbServerResourceIdForPrivateLink)
            {
                $counter = 1
                $exportRequestStatus = Get-AzSqlDatabaseImportExportStatus $exportRequest.OperationStatusLink                
                while ($exportRequestStatus.PrivateEndpointRequestStatus.Count -eq 0)
                {
                    if ($counter -ge 12)
                    {
                        Write-Error "Private link information not retrieved."
                        $exportFailed = $true
                        break
                    }
                    $counter += 1
                    Write-Host "Waiting for private link connection info..."
                    Start-Sleep -Seconds 15
                    $exportRequestStatus = Get-AzSqlDatabaseImportExportStatus $exportRequest.OperationStatusLink
                }

                $counter = 1
                $sqlServerPrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $DbServerResourceIdForPrivateLink | where { $_.Name.StartsWith('ImportExportPrivateLink_SQL') } | where {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
                while (!$sqlServerPrivateEndpointConnection)
                {
                    if ($counter -ge 12)
                    {
                        Write-Error "Azure SQL Server private link not available."
                        $exportFailed = $true
                        break
                    }
                    $counter += 1
                    Write-Host "Waiting for Azure SQL Server private link connection info..."
                    Start-Sleep -Seconds 15
                    $sqlServerPrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $DbServerResourceIdForPrivateLink | where { $_.Name.StartsWith('ImportExportPrivateLink_SQL') } | where {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
                }

                $counter = 1
                $storagePrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $StorageResourceIdForPrivateLink | where {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
                while (!$storagePrivateEndpointConnection)
                {
                    if ($counter -ge 12)
                    {
                        Write-Error "Azure Storage private link not available."
                        $exportFailed = $true
                        break
                    }
                    $counter += 1
                    Write-Host "Waiting for Storage private link connection info..."
                    Start-Sleep -Seconds 15
                    $storagePrivateEndpointConnection = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $StorageResourceIdForPrivateLink | where {$_.PrivateLinkServiceConnectionState.Status -eq "Pending" }
                }

                if ($sqlServerPrivateEndpointConnection)
                {
                    Write-Host "Accepting SQL Server private link..."
                    Approve-AzPrivateEndpointConnection -ResourceId $sqlServerPrivateEndpointConnection.Id
                }

                if ($storagePrivateEndpointConnection)
                {
                    Write-Host "Accepting Storage private link..."
                    Approve-AzPrivateEndpointConnection -ResourceId $storagePrivateEndpointConnection.Id
                }
            }

            # ELASTIC POOL - OVERLOAD PROTECTION
            # export databázi nemálo vytíží
            # tam, kde není elastic pool, s tím mnoho nenaděláme (můžeme povýšit), prostě musíme chvíli exportu přežít
            # tam, kde je elastic pool, můžeme *nezpůsobit* zátěž paralelní zálohou všech databází, čímž by měl zůstat výkový prostor pro běh aplikací
            if ($database.ElasticPoolName) # not null, not empty
            {
                $counter = 0
                do
                {
                    $counter += 1
                    if ($counter -eq 240) # 60 minut
                    {
                        Write-Warning "Timeout reached during database $($exportRequest.DatabaseName) export."
                        break
                    }
                    Start-Sleep -Second 15 # pokud by se změnilo, pozor na podmínku ukončení cyklu z důvodu timeoutu
                    $exportRequestStatus = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink
                    Write-Host "  $($counter): Database $($database.DatabaseName) export status is $($exportRequestStatus.Status) ($($exportRequestStatus.StatusMessage))."                        
                } while ($exportRequestStatus.Status -eq "InProgress")
            }
        }
        else
        {
            $exportFailed = $true;
            Write-Error "Export $($database.DatabaseName) database failed."
        }      
    }
    
    if ($exportFailed -eq $true)
    {
        throw "Database export failed."
    }

}