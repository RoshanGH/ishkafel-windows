# Windows PowerShell 5.1 runs on .NET Framework: it has neither
# ProcessStartInfo.ArgumentList nor Process.Kill(entireProcessTree). Keep all
# process-launching verification scripts on this common compatibility layer.
if (-not ('IshkafelProcessArguments' -as [type])) {
    Add-Type @'
using System;
using System.Text;

public static class IshkafelProcessArguments {
    private static string Quote(string value) {
        if (value == null || value.Length == 0) return "\"\"";
        bool needsQuotes = false;
        foreach (char c in value) {
            if (char.IsWhiteSpace(c) || c == '"') {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes) return value;

        var result = new StringBuilder();
        result.Append('"');
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') {
                slashes++;
                continue;
            }
            if (c == '"') {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes);
            slashes = 0;
            result.Append(c);
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    public static string Join(string[] values) {
        var result = new StringBuilder();
        for (int i = 0; i < values.Length; i++) {
            if (i > 0) result.Append(' ');
            result.Append(Quote(values[i]));
        }
        return result.ToString();
    }
}
'@
}

function ConvertTo-ProcessArguments {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentValues)
    return [IshkafelProcessArguments]::Join($ArgumentValues)
}
