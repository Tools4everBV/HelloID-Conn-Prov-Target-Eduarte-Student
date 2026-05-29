#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-Update
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-Eduarte-StudentError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            # Todo: The error message may need to be be changed to show to friendly message

            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            # Make sure to inspect the error result object and add only the error message as a FriendlyMessage.
            # $httpErrorObj.FriendlyMessage = $errorDetailsObject.message
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails # Temporarily assignment
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            Write-Warning $_.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}

function ConvertFrom-Xml {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Node
    )

    process {
        $ht = [ordered]@{}
        $arrKeys = @()

        if ($Node.Attributes) {
            foreach ($attr in $Node.Attributes) {
                $ht[$attr.Name] = $attr.Value
            }
        }

        foreach ($child in $Node.ChildNodes) {
            if ($child.NodeType -ne "Element") {
                continue
            }

            $key = $child.LocalName
            $hasOnlyText =
            $child.ChildNodes.Count -eq 1 -and
            $child.FirstChild.NodeType -eq "Text"

            if ($hasOnlyText) {
                $value = $child.InnerText
            }
            else {
                $value = ConvertFrom-Xml -Node $child
            }

            # Handle arrays
            if ($ht.Contains($key)) {

                if (-not ($ht[$key] -is [System.Collections.IList])) {
                    $ht[$key] = @($ht[$key])
                    $arrKeys += $key
                }
                $ht[$key] += $value
            }
            else {
                $ht[$key] = $value
            }
        }

        [PSCustomObject]$ht
    }
}
#endregion

try {
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    Write-Information 'Verifying if a Eduarte-Student account exists'
    # Get Student XML call
    [xml]$getStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
        <soapenv:Header/>
        <soapenv:Body>
        <api:getDeelnemer>
            <!--Optional:-->
            <apiSleutel>?</apiSleutel>
            <deelnemernummer>?</deelnemernummer>
        </api:getDeelnemer>
        </soapenv:Body>
    </soapenv:Envelope>'

    $getStudent.Envelope.Body.getDeelnemer.apiSleutel = $actionContext.Configuration.ApiKey
    $getStudent.Envelope.Body.getDeelnemer.deelnemernummer = $actionContext.References.Account

    $splatGetStudent = @{
        Uri         = "$($actionContext.Configuration.BaseUrl)/services/api/algemeen/deelnemers" 
        Method      = 'Post'
        ContentType = "text/xml; charset=utf-8" 
        Body        = $getStudent.InnerXml
    }
    $rawResponse = Invoke-RestMethod @splatGetStudent
    $correlatedAccount = ([xml]$rawResponse).Envelope.body.getDeelnemerResponse.deelnemer

    if (-NOT [string]::isNullOrEmpty($correlatedAccount.gebruikersNaam)) {
        $correlatedAccount = (ConvertFrom-Xml $correlatedAccount)
        $mailProperty = ($correlatedAccount.contactgegevens.contactgegeven | Where-Object { $_.soort.code -eq "$($actionContext.configuration.ContactGegevenCode)" }).contactgegeven

        $outputContext.previousData = ($correlatedAccount | Select-Object -Property $outputContext.data.PSObject.Properties.Name)
        $outputContext.PreviousData.emailadres = $mailProperty

        # Always compare the account against the current account in target system
        # Todo change update check to your needs
        # Todo: Check if the email adres can be found in the [contactgegevens].
        # Todo: Check if the API supports updating email to null or empty string. If not add ([string]::IsNullOrEmpty($account.EmailAddress)) check to if-statement.

        if ($mailProperty -ne $actionContext.data.emailadres) {
            $propertiesChanged = [PSCustomObject]@{
                Name          = 'emailadres'
                Value         = $actionContext.data.emailadres
                SideIndicator = '=>'
            }
        }
    }

    if ($propertiesChanged) {
        $lifecycleProcess = 'UpdateAccount'
    }
    elseif ((-not ($propertiesChanged) -And (-not ([string]::isNullOrEmpty($correlatedAccount.gebruikersNaam))))) {
        $lifecycleProcess = 'NoChanges'
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'UpdateAccount' {
            Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"

            [xml]$setStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:updateContactgegevens>
                        <apiSleutel>?</apiSleutel>
                        <deelnemerNummer>?</deelnemerNummer>
                        <contactgegeven>
                            <contactgegeven>?</contactgegeven>
                            <soort>
                                <code>?</code>
                                <naam>?</naam>
                            </soort>
                            <geheim>false</geheim>
                        </contactgegeven>
                    </api:updateContactgegevens>
                    </soapenv:Body>
                </soapenv:Envelope>'

            $setStudent.envelope.body.updateContactgegevens.apiSleutel = "$($actionContext.Configuration.ApiKey)"
            $setStudent.envelope.body.updateContactgegevens.deelnemerNummer = "$($actionContext.References.Account)"
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.contactgegeven = "$($actionContext.data.emailadres)"
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.soort.code = "$($actionContext.configuration.ContactGegevenCode)"
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.soort.naam = "$($actionContext.configuration.ContactGegevenNaam)"

            $splatSetStudent = @{
                Method      = 'Post'
                Uri         = "$($actionContext.Configuration.BaseUrl)/services/api/algemeen/deelnemers"
                ContentType = "text/xml; charset=utf-8" 
                Body        = $setStudent.InnerXml
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Updating Eduarte-Student account with accountReference: [$($actionContext.References.Account)]"
                $null = Invoke-RestMethod @splatSetStudent
            }
            else {
                Write-Information "[DryRun] Update Eduarte-Student account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                    IsError = $false
                })
            break
        }

        'NoChanges' {
            Write-Information "No changes to Eduarte-Student account with accountReference: [$($actionContext.References.Account)]"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Skipped updating Eduarte-Student account with AccountReference: [$($actionContext.References.Account)]. Reason: No changes."
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Eduarte-Student account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Eduarte-Student account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
                    IsError = $true
                })
            break
        }
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Eduarte-StudentError -ErrorObject $ex
        $auditLogMessage = "Could not update Eduarte-Student account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not update Eduarte-Student account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
