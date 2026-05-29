##################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-Disable
# PowerShell V2
##################################################

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
    
    $getStudent.Envelope.Body.getDeelnemer.apiSleutel = "$($actionContext.Configuration.ApiKey)"
    $getStudent.Envelope.Body.getDeelnemer.deelnemernummer = "$($actionContext.References.Account)"

    $splatGetStudent = @{
        Uri         = "$($actionContext.Configuration.BaseUrl)/services/api/algemeen/deelnemers" 
        Method      = 'Post'
        ContentType = "text/xml; charset=utf-8" 
        Body        = $getStudent.InnerXml
    }
    $rawResponse = Invoke-RestMethod @splatGetStudent
    $correlatedAccount = ([xml]$rawResponse).Envelope.body.getDeelnemerResponse.deelnemer

    if (-NOT [string]::isNullOrEmpty($correlatedAccount.gebruikersNaam)) {
        $lifecycleProcess = 'DisableAccount'
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'DisableAccount' {
            # Disable Student XML call
                [xml]$disableStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:deactiveerGebruiker>
                        <apiSleutel>?</apiSleutel>
                        <gebruikernaam>?</gebruikernaam>
                    </api:deactiveerGebruiker>
                    </soapenv:Body>
                </soapenv:Envelope>' 

                $disableStudent.envelope.body.deactiveerGebruiker.apiSleutel = "$($actionContext.Configuration.ApiKey)"
                $disableStudent.envelope.body.deactiveerGebruiker.gebruikernaam = $correlatedAccount.gebruikersNaam

                $splatDisableStudent = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/services/api/algemeen/gebruikers" 
                    Method      = 'Post'
                    ContentType = "text/xml; charset=utf-8" 
                    Body        = $disableStudent.InnerXml
                }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Disabling Eduarte-Student account with accountReference: [$($actionContext.References.Account)]"

                $null = Invoke-RestMethod @splatDisableStudent
            }
            else {
                Write-Information "[DryRun] Disable Eduarte-Student account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Disable account: [$($actionContext.References.Account)] was successful. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Eduarte-Student account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Eduarte-Student account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Eduarte-StudentError -ErrorObject $ex
        $auditLogMessage = "Could not disable Eduarte-Student account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not disable Eduarte-Student account: [$($actionContext.References.Account)]. Error: $($_.Exception.Message). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}