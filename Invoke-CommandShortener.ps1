
function Invoke-CommandShortener
{
   <#
         .SYNOPSIS
         Shortens and simplifies a PowerShell script block by replacing command names with aliases and using shortest parameter aliases.
   
         .DESCRIPTION
         The Invoke-CommandShortener function takes a PowerShell script block as input and performs the following tasks:
      
         1. Splits the input script block into individual lines, removing empty lines and delimiters.
         2. Identifies command delimiters in the input script block.
         3. Parses the input script block into an Abstract Syntax Tree (AST).
         4. Extracts a list of command elements and their associated parameters from the AST.
         5. Creates a list of command information, including aliases and parameters.
         6. Replaces command names with their aliases and parameter names with their shortest aliases.
         7. Returns the modified script block.
   
         .PARAMETER InputScriptBlock
         Specifies the PowerShell script block that you want to shorten and simplify.
   
         .EXAMPLE
         Invoke-CommandShortener -InputScriptBlock {Foreach-Object -Process {"Blub"}
         Get-ChildItem -Path C:\Temp -Hidden;Cls }
      
         Output:
         % -Process {"Blub"}
         ls -Path C:\Temp -h;Cls
      
      
         # $shortenedScript will contain the modified script block with shortened command names and aliases.
   
         .EXAMPLE
         Invoke-CommandShortener -InputScriptBlock {Get-Process | Where-Object { $_.CPU -gt 50 }}
      
         Output:
         ps | ? { $_.CPU -gt 50 }
      
      
         # $shortenedScript will contain the modified script block with shortened command names and aliases.
   
         .NOTES
         File Name      : Invoke-CommandShortener.ps1
         Original Author: Christian Ritter
         Prerequisite   : PowerShell v5, or later
         Forked version : 0.3
   
         .LINK
         https://github.com/jhochwald/PSCommandShortener
   #>
   [CmdletBinding(ConfirmImpact = 'Low')]
   param
   (
      [Parameter(Mandatory,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName,
      HelpMessage = 'Specifies the PowerShell script block that you want to shorten and simplify.')]
      [ValidateNotNullOrEmpty()]
      [scriptblock]
      $InputScriptBlock
   )
   
   process
   {
      # Split the input script block into individual lines, removing empty lines and delimiters
      $ScriptblockText = (New-Object -TypeName 'System.Collections.ArrayList')
      $ScriptblockText.AddRange(@($InputScriptBlock.ToString().Trim() -split "(?<=;|`n|\|)" | ForEach-Object -Process {
               ($_ -replace "[;`n|]")
            } | Where-Object -FilterScript {
               ($_ -match '\S')
      }))
      
      # Identify command delimiters in the input script block
      $commandDelimiters = $InputScriptBlock.ToString() | Select-String -Pattern '(\n|\||;)' -AllMatches | ForEach-Object -Process {
         ($_.Matches.Value)
      }
      
      # Parse the input script block into an Abstract Syntax Tree (AST)
      $ast = [Management.Automation.Language.Parser]::ParseInput($InputScriptBlock.ToString(), [ref]$null, [ref]$null)
      
      # Extract a list of command elements and their associated parameters from the AST
      $commandElementList = $ast.FindAll({
            ($args[0].GetType().Name -like 'CommandAst')
      }, $true) | ForEach-Object -Process {
         [pscustomobject]@{
            Cmdlet     = $_.CommandElements[0].Value
            Parameters = $_.CommandElements.ParameterName
         }
      }
      
      # Create a list of command information, including aliases and parameters
      $list = foreach ($commandElementListItem in $commandElementList)
      {
         $command = Get-Command -Name $commandElementListItem.Cmdlet
         $commandAlias = $null
         
         # Determine if the command is an alias and resolve it if necessary
         switch ($command)
         {
            {
               $PSItem.Commandtype -eq 'Alias'
            } 
            {
               $commandAlias = $commandElementListItem.Cmdlet
               $command = (Get-Command -Name $PSItem.ResolvedCommand)
            }
            Default 
            {
               # Find the shortest alias for the command if it's not an alias itself
               try
               {
                  $commandAlias = ((Get-Alias -Definition $commandElementListItem.Cmdlet -ErrorAction Stop).DisplayName.ForEach{
                        $_.Split('-')[0]
                  }) | Sort-Object -Property Length | Select-Object -First 1
               }
               catch
               {
                  $commandAlias = $null
               }
            }
         }
         
         $parameters = [ordered]@{
         }
         
         # Match command parameters with their aliases and select the shortest alias or unique match
         foreach ($commandElementListItemParameterItem in $commandElementListItem.Parameters)
         {
            switch ((Get-Command -Name $command.Name | Select-Object -ExpandProperty ParameterSets).Parameters | Where-Object -FilterScript {
                  ($_.Name -eq $commandElementListItemParameterItem) -or ($_.Aliases.contains($commandElementListItemParameterItem))
            })
            {
               {
                  ($commandElementListItemParameterItem -eq $PSItem.Aliases) -or ($commandElementListItemParameterItem -eq $PSItem.Name) -and (-not [string]::IsNullOrEmpty($PSItem.Aliases))
               } 
               {
                  # If the parameter is an alias, select the shortest alias
                  $parameters[$PSItem.Name] = $($PSItem.Aliases | Sort-Object -Property Length | Select-Object -First 1)
               }
               Default 
               {
                  # Find the shortest unique parameter match
                  $ShortestUniqueParameterMatch = ''
                  # Iterate through each character in the parameter string
                  foreach ($Char in $commandElementListItemParameterItem.ToCharArray())
                  {
                     $ShortestUniqueParameterMatch += $Char
                     
                     # Count how many parameters start with the current match
                     $count = ((Get-Command -Name $command.Name | Select-Object -ExpandProperty ParameterSets).Parameters.Name | Where-Object -FilterScript {
                           $_ -like ('{0}*' -f $ShortestUniqueParameterMatch)
                     }).Count
                     
                     if ($count -eq 1)
                     {
                        break # Exit the loop when count equals 1 (shortest unique match found)
                     }
                  }
                  $parameters[$PSItem.Name] = $ShortestUniqueParameterMatch
               }
            }
         }
         
         [PSCustomObject]@{
            CommandAlias = $commandAlias
            CommandName  = $command.Name
            Parameters   = $parameters
         }
      }
      
      # Initialize the final script block text
      $finalScriptBlockText = ''
      
      # Process each line of the script block
      for ($i = 0; $i -lt $ScriptblockText.Count; $i++)
      {
         # Replace command names with their aliases or implied 'Get-' if available
         switch -Wildcard ($list[$i].CommandName)
         {
            {
               -not [string]::IsNullOrEmpty($list[$i].CommandAlias)
            } 
            {
               $ScriptblockText[$i] = $ScriptblockText[$i] -replace $list[$i].CommandName, $list[$i].CommandAlias
            }
            {
               $_ -like 'Get-*'
            } 
            {
               $ScriptblockText[$i] = $ScriptblockText[$i] -replace $list[$i].CommandName, ($_ -replace 'Get-')
            }
         }
         
         
         switch ($list[$i].Parameters.GetEnumerator())
         {
            # Replace parameter names with their shortest aliases
            {
               -not [string]::IsNullOrEmpty($_.Value)
            } 
            {
               $ScriptblockText[$i] = $ScriptblockText[$i] -replace $_.Key, $_.Value
            }
         }
         # Append the modified line to the final script block text
         $finalScriptBlockText += $ScriptblockText[$i]
         
         # Append the command delimiter if present
         if ($i -lt $commandDelimiters.Count)
         {
            $finalScriptBlockText += $commandDelimiters[$i]
         }
      }
      
      # Replace line breaks with CRLF and remove extra spaces
      $finalScriptBlockText = $finalScriptBlockText -replace '(?<!\r)\n', "`r`n" -replace ' {2,}', ' '
   }
   
   end
   {
      # Create and return the modified script block
      return $([scriptblock]::Create($finalScriptBlockText))
   }
}
