#################################################
# HelloID-Conn-Prov-Target-Eduarte-Student-Create
#
# Version: 1.0.1
#################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

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
        # Todo: The error message may need to be neatened for the friendlyerror message
        if ($ErrorObject.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
            $httpErrorObj.FriendlyMessage = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException' -and (-not [string]::IsNullOrEmpty($ErrorObject.Exception.Response))) {
            $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
            if ( $streamReaderResponse ) {
                $httpErrorObj.ErrorDetails = $streamReaderResponse
                $httpErrorObj.FriendlyMessage = $streamReaderResponse
            }
        }
        Write-Output $httpErrorObj
    }
}

function Add-XmlElement {
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory,
            ValueFromPipeline = $True,
            Position = 0)]
        [System.Xml.XmlElement]
        $XmlParentDocument,

        [Parameter(Mandatory)]
        [string]
        $ElementName,

        [Parameter(Mandatory)]
        [string]
        [AllowEmptyString()]
        $ElementValue
    )
    process {
        try {
            $child = $XmlParentDocument.OwnerDocument.CreateElement($ElementName)
            $null = $child.InnerText = "$ElementValue"
            $null = $XmlParentDocument.AppendChild($child)
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}


function Get-RandomCharacters([int]$length, $characters) {
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length } 

    return [String]$characters[$random]
}

#region Support Functions
function New-RandomPassword() {
    #passwordSpecifications:
    $length = 8
    $upper = 1
    $number = 1
    $special = 1
    $lower = $length - $upper - $number - $special
      
    $chars = "abcdefghkmnprstuvwxyz"
    $NumberPool = "23456789"
    $specialPool = "!#"

    $CharPoolLower = $chars.ToLower()
    $CharPoolUpper = $chars.ToUpper()

    $password = Get-RandomCharacters -characters $CharPoolUpper -length $upper
    $password += Get-RandomCharacters -characters $NumberPool -length $number
    $password += Get-RandomCharacters -characters $specialPool -length $special
    $password += Get-RandomCharacters -characters $CharPoolLower -length $Lower

    $passwordArray = $password.ToCharArray()   
    $passwordScrambledArray = $passwordArray | Get-Random -Count $passwordArray.Length     
    $password = -join $passwordScrambledArray
    $password = $password -replace ("[^a-z0-9#!]")
    return $password 
}

#endregion

# Begin
try {

    # Account mapping
    $account = [PSCustomObject]@{
        ExternalId   = $p.ExternalId
        UserName     = $p.Accounts.ActiveDirectory.samaccountname
        Password     = New-RandomPassword
        Contactgegeven = @{
            Contactgegeven = $p.Accounts.ActiveDirectory.mail 
            soort = $config.ContactgegevenSoort
            naam = $config.contactgegevenNaam
        }
    }    

    # Verify if [account.ExternalId] has a value
    if ([string]::IsNullOrEmpty($($account.ExternalId))) {
        throw 'Mandatory attribute [account.ExternalId] is empty. Please make sure it is correctly mapped'
    }

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
    </soapenv:Envelope>
    '

    $getStudent.Envelope.Body.getDeelnemer.apiSleutel = $config.apiKey
    $getStudent.Envelope.Body.getDeelnemer.deelnemernummer = $account.ExternalId

    $splatGetStudent = @{
        Uri             = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers" 
        Method          = 'POST'
        Body            = $getStudent.InnerXml
        ContentType     = 'text/xml; charset=utf-8'
        UseBasicParsing = $true
    }


    $rawResponse = Invoke-RestMethod @splatGetStudent -Verbose:$true

    $responseStudent = ([xml]$rawResponse).Envelope.body.getDeelnemerResponse.deelnemer

    $userFound = $responseStudent.gebruikersNaam

    # Todo: Check if correlation condition works as expected
    if ([string]::isNullOrEmpty($userFound)) {
        $action = 'Create'
    }
    elseif ($config.updatePersonOnCorrelate -eq $true) {
        $action = 'Update-Correlate'
    }
    else {
        $action = 'Correlate'
    }

    # Add a warning message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $action Eduarte-Student account for: [$($p.DisplayName)], will be executed during enforcement"
    }

    # Process
  
    switch ($action) {
        'Create' {
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

            $createStudent.envelope.body.createDeelnemerGebruiker.apiSleutel = "$($config.ApiKey)"
            $createStudent.envelope.body.createDeelnemerGebruiker.deelnemernummer = "$($account.ExternalId)"
            $createStudent.envelope.body.createDeelnemerGebruiker.gebruikersnaam = "$($account.UserName)"
            $createStudent.envelope.body.createDeelnemerGebruiker.emailadres = "$($account.EmailAddress)"
            $createStudent.envelope.body.createDeelnemerGebruiker.wachtwoord = "$($account.Password)"

            $splatCreateStudent = @{
                Method      = 'Post'
                Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/gebruikers"
                ContentType = "text/xml" 
                Body        = $createStudent.InnerXml
            }

            if (-not($dryRun -eq $true)) {
                $null = Invoke-RestMethod @splatCreateStudent -Verbose:$false
            }else{
                Write-warning "send: $($createStudent.InnerXml)"
            }

            $accountReference = $account.ExternalId
            $auditLogs.Add([PSCustomObject]@{
                    Message = "Create account was successful. AccountReference is: [$accountReference]"
                    IsError = $false
                })
        }

        'Update-Correlate' {
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


            $currentMailProperty = ($responseStudent.contactgegevens.contactgegeven | where-object { $_.soort.code -eq $account.contactgegeven.soort }).contactgegeven

            $setStudent.envelope.body.updateContactgegevens.apiSleutel = "$($config.ApiKey)"
            $setStudent.envelope.body.updateContactgegevens.deelnemernummer = "$($account.ExternalId)"
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.contactgegeven = $account.Contactgegeven.Contactgegeven
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.soort.code = $account.contactgegeven.soort
            $setStudent.envelope.body.updateContactgegevens.contactgegeven.soort.naam = $account.contactgegeven.naam

            # Todo: Check if the email adres can be found in the [contactgegevens]
            if ((-not [string]::IsNullOrEmpty($account.Contactgegeven.Contactgegeven)) -and ($currentMailProperty -ne $account.Contactgegeven.Contactgegeven)) {
                $updateRequired = $true
            }
            else {
                Write-warning "No update needed"
            }

            # Todo: Check deelnemernummer location
            $accountReference = $responseStudent.deelnemernummer

            if ($updateRequired) {
                $splatSetStudent = @{
                    Method      = 'Post'
                    Uri         = "$($config.BaseUrl.TrimEnd('/'))/services/api/algemeen/deelnemers"
                    ContentType = "text/xml" 
                    Body        = $setStudent.InnerXml
                }

                # Todo: Check possible the response!
                if (-not($dryRun -eq $true)) {
                    $response = Invoke-RestMethod @splatSetStudent -Verbose:$false
                        
                    $responsemessage = $response.Envelope.body.updateContactgegevensResponse.updateContactgegevensResponse
                    Write-Verbose -Verbose "response $($responsemessage.status) - $($responsemessage.melding)"
                }

                $auditLogs.Add([PSCustomObject]@{
                        Message = "Update account was successful. AccountReference is: [$accountReference]"
                        IsError = $false
                    })
            }
            else {
                $auditLogs.Add([PSCustomObject]@{
                        Message = "No Update account required. AccountReference is: [$accountReference]"
                        IsError = $false
                    })
            }
            break
        }
        'correlate' {
            Write-Verbose 'Correlating Eduarte student'
            $accountReference = $responseStudent.deelnemernummer
            break
        }

            
    }
    $success = $true
    $auditLogs.Add([PSCustomObject]@{
            Message = "$action account was successful. AccountReference is: [$($accountReference)]"
            IsError = $false
        })
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Eduarte-StudentError -ErrorObject $ex
        $auditMessage = "Could not $action Eduarte-Student account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not $action Eduarte-Student account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $accountReference
        Auditlogs        = $auditLogs
        Account          = $account
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}