#!/usr/bin/pwsh
# This file is part of Ansible

# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#region Helper functions

Function Exit-Json($obj)
{
<#
    .SYNOPSIS
    Helper function to convert a PowerShell object to JSON and output it, exiting
    the script
    .EXAMPLE
    Exit-Json $result
#>

    # If the provided $obj is undefined, define one to be nice
    If (-not $obj.GetType)
    {
        $obj = @{ }
    }

    if (-not $obj.ContainsKey('changed')) {
        Set-Attr -obj $obj -name "changed" -value $false
    }

    Write-Output $obj | ConvertTo-Json -Compress -Depth 99
    Exit
}

Function Set-Attr($obj, $name, $value)
{
	# If the provided $obj is undefined, define one to be nice
	If (-not $obj.GetType)
	{
		$obj = @{ }
	}
	
	Try
	{
		$obj.$name = $value
	}
	Catch
	{
		$obj | Add-Member -Force -MemberType NoteProperty -Name $name -Value $value
	}
}


Function Fail-Json($obj, $message = $null)
{
	if ($obj -is [hashtable] -or $obj -is [psobject])
	{
		# Nothing to do
	}
	elseif ($obj -is [string] -and $message -eq $null)
	{
		# If we weren't given 2 args, and the only arg was a string,
		# create a new Hashtable and use the arg as the failure message
		$message = $obj
		$obj = @{ }
	}
	else
	{
		# If the first argument is undefined or a different type,
		# make it a Hashtable
		$obj = @{ }
	}
	
	# Still using Set-Attr for PSObject compatibility
	Set-Attr $obj "msg" $message
	Set-Attr $obj "failed" $true
	
	if (-not $obj.ContainsKey('changed'))
	{
		Set-Attr $obj "changed" $false
	}
	
	write-output $obj | ConvertTo-Json -Compress -Depth 99
	Exit 1
}

Function Get-AnsibleParam($obj, $name, $default = $null, $resultobj = @{ }, $failifempty = $false, $emptyattributefailmessage, $ValidateSet, $ValidateSetErrorMessage, $type = $null, $aliases = @())
{
	# Check if the provided Member $name or aliases exist in $obj and return it or the default.
	try
	{
		
		$found = $null
		# First try to find preferred parameter $name
		$aliases = @($name) + $aliases
		
		# Iterate over aliases to find acceptable Member $name
		foreach ($alias in $aliases)
		{
			if ($obj.ContainsKey($alias))
			{
				$found = $alias
				break
			}
		}
		
		if ($found -eq $null)
		{
			throw
		}
		$name = $found
		
		if ($ValidateSet)
		{
			
			if ($ValidateSet -contains ($obj.$name))
			{
				$value = $obj.$name
			}
			else
			{
				if ($ValidateSetErrorMessage -eq $null)
				{
					#Auto-generated error should be sufficient in most use cases
					$ValidateSetErrorMessage = "Get-AnsibleParam: Argument $name needs to be one of $($ValidateSet -join ",") but was $($obj.$name)."
				}
				Fail-Json -obj $resultobj -message $ValidateSetErrorMessage
			}
			
		}
		else
		{
			$value = $obj.$name
		}
		
	}
	catch
	{
		if ($failifempty -eq $false)
		{
			$value = $default
		}
		else
		{
			if (!$emptyattributefailmessage)
			{
				$emptyattributefailmessage = "Get-AnsibleParam: Missing required argument: $name"
			}
			Fail-Json -obj $resultobj -message $emptyattributefailmessage
		}
		
	}
	
	# If $value -eq $null, the parameter was unspecified by the user (deliberately or not)
	# Please leave $null-values intact, modules need to know if a parameter was specified
	# When $value is already an array, we cannot rely on the null check, as an empty list
	# is seen as null in the check below
	if ($value -ne $null -or $value -is [array])
	{
		if ($type -eq "path")
		{
			# Expand environment variables on path-type
			$value = Expand-Environment($value)
			# Test if a valid path is provided
			if (-not (Test-Path -IsValid $value))
			{
				$path_invalid = $true
				# could still be a valid-shaped path with a nonexistent drive letter
				if ($value -match "^\w:")
				{
					# rewrite path with a valid drive letter and recheck the shape- this might still fail, eg, a nonexistent non-filesystem PS path
					if (Test-Path -IsValid $(@(Get-PSDrive -PSProvider Filesystem)[0].Name + $value.Substring(1)))
					{
						$path_invalid = $false
					}
				}
				if ($path_invalid)
				{
					Fail-Json -obj $resultobj -message "Get-AnsibleParam: Parameter '$name' has an invalid path '$value' specified."
				}
			}
		}
		elseif ($type -eq "str")
		{
			# Convert str types to real Powershell strings
			$value = $value.ToString()
		}
		elseif ($type -eq "bool")
		{
			# Convert boolean types to real Powershell booleans
			$value = $value | ConvertTo-Bool
		}
		elseif ($type -eq "int")
		{
			# Convert int types to real Powershell integers
			$value = $value -as [int]
		}
		elseif ($type -eq "float")
		{
			# Convert float types to real Powershell floats
			$value = $value -as [float]
		}
		elseif ($type -eq "list")
		{
			if ($value -is [array])
			{
				# Nothing to do
			}
			elseif ($value -is [string])
			{
				# Convert string type to real Powershell array
				$value = $value.Split(",").Trim()
			}
			elseif ($value -is [int])
			{
				$value = @($value)
			}
			else
			{
				Fail-Json -obj $resultobj -message "Get-AnsibleParam: Parameter '$name' is not a YAML list."
			}
			# , is not a typo, forces it to return as a list when it is empty or only has 1 entry
			return, $value
		}
	}
	
	return $value
}

#Alias Get-attr-->Get-AnsibleParam for backwards compat. Only add when needed to ease debugging of scripts
If (!(Get-Alias -Name "Get-attr" -ErrorAction SilentlyContinue))
{
	New-Alias -Name Get-attr -Value Get-AnsibleParam
}

# Helper filter/pipeline function to convert a value to boolean following current
# Ansible practices
# Example: $is_true = "true" | ConvertTo-Bool
Function ConvertTo-Bool
{
	param (
		[parameter(valuefrompipeline = $true)]
		$obj
	)
	
	$boolean_strings = "yes", "on", "1", "true", 1
	$obj_string = [string]$obj
	
	if (($obj -is [boolean] -and $obj) -or $boolean_strings -contains $obj_string.ToLower())
	{
		return $true
	}
	else
	{
		return $false
	}
}

Function Parse-Args($arguments, $supports_check_mode = $false)
{
	$params = New-Object psobject
	If ($arguments.Length -gt 0)
	{
        $params = Get-Content $arguments[0] -raw | ConvertFrom-Json -AsHashtable
	}
	Else
	{
		$params = $complex_args
	}
	$check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -type "bool" -default $false
	If ($check_mode -and -not $supports_check_mode)
	{
		Exit-Json @{
			skipped = $true
			changed = $false
			msg	    = "remote module does not support check mode"
		}
	}
	return $params
}

#Alias Get-attr-->Get-AnsibleParam for backwards compat. Only add when needed to ease debugging of scripts
If (!(Get-Alias -Name "Get-attr" -ErrorAction SilentlyContinue))
{
	New-Alias -Name Get-attr -Value Get-AnsibleParam
}


##endregion



$ErrorActionPreference = 'Stop'
#
## WANT_JSON
#
# The module is invoked with the path to the input args as the first argument,
# we read the file at the path and convert the JSON to a hashtable
$input_json = Get-Content -Path $args[0] -Raw
$params = ConvertFrom-Json -InputObject $input_json -AsHashtable

# Define our return json, using $params.foo means we want the foo module option
# from Ansible.
$output = Get-AnsibleParam -obj $params -name "output" -type "str" -failifempty $true

$result = @{
	changed   = $false
	msg       = $output
}

$result.changed = $true 
Exit-Json -obj $result

# Reference
# https://docs.ansible.com/ansible/2.6/dev_guide/developing_modules_general_windows.html
# https://docs.ansible.com/ansible/2.4/dev_guide/developing_modules_general_windows.html
