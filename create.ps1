#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-Create
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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        Write-Information "Verifying if a Eduarte-Student account exists where $correlationField is: [$correlationValue]"

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
        $getStudent.Envelope.Body.getDeelnemer.deelnemernummer = "$($correlationValue)"

        $splatGetStudent = @{
            Uri         = "$($actionContext.Configuration.BaseUrl)/services/api/algemeen/deelnemers" 
            Method      = 'POST'
            ContentType = "text/xml; charset=utf-8" 
            Body        = $getStudent.InnerXml
        }

        $rawResponse = Invoke-RestMethod @splatGetStudent
        if($null -eq $rawResponse.Envelope.body.getDeelnemerResponse) {
            throw "($rawResponse.substring(0, 100))"
        }
        $correlatedAccount = ([xml]$rawResponse).Envelope.body.getDeelnemerResponse.deelnemer
    }

    # Todo: Check if correlation condition works as expected
    if ([string]::isNullOrEmpty($correlatedAccount.gebruikersNaam)) {
        $lifecycleProcess = 'CreateAccount'
    }
    elseif (-not ([string]::isNullOrEmpty($correlatedAccount.gebruikersNaam))) {
        $lifecycleProcess = 'CorrelateAccount'
    }
    elseif ($correlatedAccount.gebruikersNaam.Count -gt 1) {
        throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
    }

    # Process
    switch ($lifecycleProcess) {
        'CreateAccount' {
            [xml]$createStudent = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:api="http://api.algemeen.webservices.eduarte.topicus.nl/">
                    <soapenv:Header/>
                    <soapenv:Body>
                    <api:createDeelnemerGebruiker>
                        <apiSleutel>?</apiSleutel>
                        <deelnemernummer>?</deelnemernummer>
                        <gebruikersnaam>?</gebruikersnaam>
                        <wachtwoord>?</wachtwoord>
                        <emailadres>?</emailadres>
                    </api:createDeelnemerGebruiker>
                    </soapenv:Body>
                </soapenv:Envelope>'

            # Todo Email is an optional field, check if property needs to be set and what happends when $actionContext.Data.emailadres is empty
            $createStudent.envelope.body.createDeelnemerGebruiker.apiSleutel = "$($actionContext.Configuration.ApiKey)"            
            $createStudent.envelope.body.createDeelnemerGebruiker.deelnemernummer = "$($actionContext.Data.deelnemerNummer)"
            $createStudent.envelope.body.createDeelnemerGebruiker.gebruikersnaam = "$($actionContext.Data.gebruikersnaam)"
            $createStudent.envelope.body.createDeelnemerGebruiker.emailadres = "$($actionContext.Data.emailadres)"
            $createStudent.envelope.body.createDeelnemerGebruiker.wachtwoord = "$($actionContext.Data.Password)"

            $splatCreateParams = @{
                Method      = 'Post'
                Uri         = "$($actionContext.Configuration.BaseUrl)/services/api/algemeen/gebruikers"
                ContentType = "text/xml; charset=utf-8" 
                Body        = $createStudent.InnerXml
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating Eduarte-Student account'

                $rawResponse = Invoke-RestMethod @splatCreateParams
                $createdAccount = ([xml]$rawResponse).Envelope.body.createDeelnemerGebruikerResponse
                $createdAccount = ConvertFrom-Xml $createdAccount

                $outputContext.Data = ($createdAccount | Select-Object -Property $outputContext.data.PSObject.Properties.Name)  
                $outputContext.AccountReference = $createdAccount.deelnemerNummer
            }
            else {
                Write-Information '[DryRun] Create and correlate Eduarte-Student account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Eduarte-Student account'

            $correlatedAccount = (ConvertFrom-Xml $correlatedAccount)
            $outputContext.Data =  ($correlatedAccount | Select-Object -Property $outputContext.data.PSObject.Properties.Name)
            $outputContext.Data.emailadres = ($correlatedAccount.contactgegevens.contactgegeven | Where-Object { $_.soort.code -eq "$($actionContext.configuration.ContactGegevenCode)" }).contactgegeven

            $outputContext.AccountReference = $correlatedAccount.deelnemerNummer
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $lifecycleProcess
            Message = $auditLogMessage
            IsError = $false
        })
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Eduarte-StudentError -ErrorObject $ex
        $auditLogMessage = "Could not create or correlate Eduarte-Student account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not create or correlate Eduarte-Student account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}