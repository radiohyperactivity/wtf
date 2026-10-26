package cli

import (
	"flag"
	"fmt"
	"strings"
)

// Shell completion: "wtf completion SHELL" prints a script that makes the
// shell call "wtf __complete SHELL …" on Tab. That prints one candidate per
// line, or ":files" to fall back to the shell's file name completion.

func completionCommand() command {
	return command{
		name:    "completion",
		args:    "<bash|zsh|powershell>",
		summary: "Print the shell code for Tab completion; see 'wtf completion -h'.",
		params:  []param{arg("Shell", words("bash", "zsh", "powershell"))},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			fs.Usage = func() {
				fmt.Fprint(fs.Output(), `Usage: wtf completion <bash|zsh|powershell>

Prints the code that sets up Tab completion of commands, flags and objects
(locations, items, attributes, …, fetched from the server). Load it from your
shell's startup file:

  bash (~/.bashrc):            eval "$(wtf completion bash)"
  zsh (~/.zshrc, after compinit): source <(wtf completion zsh)
  PowerShell ($PROFILE):       wtf completion powershell | Out-String | Invoke-Expression
`)
			}
			return func(e *env, args []string) error {
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				script, ok := map[string]string{"bash": bashScript, "zsh": zshScript, "powershell": powershellScript}[args[0]]
				if !ok {
					return usagef("unknown shell %q: use bash, zsh or powershell", args[0])
				}
				_, err := fmt.Fprint(e.stdout, script)
				return err
			}
		},
	}
}

// complete runs "wtf __complete SHELL …". It never fails: without a server
// or login, only commands and flags are completed.
func (e *env) complete(args []string) int {
	if len(args) == 0 {
		return 2
	}
	e.completing = true
	_ = e.init()
	if e.api == nil {
		e.api = newClient("", "")
	}
	shell, args := args[0], args[1:]

	var words []string
	quote, raw, bashCur := byte(0), "", ""
	switch shell {
	case "bash":
		// The line up to the cursor, and bash's own current word, which
		// may be only the end of ours (bash splits words at "=" and ":").
		if len(args) != 2 {
			return 2
		}
		var tokens []string
		tokens, raw, quote = splitShellLine(args[0])
		if len(tokens) == 0 {
			return 0
		}
		words, bashCur = tokens[1:], args[1]
	case "zsh":
		words = args
	case "powershell":
		// Each word comes as "w:…", because PowerShell drops empty arguments.
		for _, a := range args {
			words = append(words, strings.TrimPrefix(a, "w:"))
		}
	default:
		return 2
	}
	if len(words) == 0 {
		words = []string{""}
	}

	cands, files := e.candidates(words, false)
	if files {
		fmt.Fprintln(e.stdout, ":files")
		return 0
	}
	for _, c := range filterCandidates(cands, words[len(words)-1]) {
		if shell == "bash" {
			c = bashReplacement(c, raw, bashCur, quote)
			if c == "" {
				continue
			}
		}
		fmt.Fprintln(e.stdout, c)
	}
	return 0
}

// splitShellLine splits a bash command line like the shell would. It
// returns the unquoted words (the last is the word being completed, "" after
// a space), the raw text of the last word, and the quote it is still open
// in, if any.
func splitShellLine(line string) ([]string, string, byte) {
	var (
		words   []string
		cur     strings.Builder
		inWord  bool
		quote   byte
		start   int
		escaped bool
	)
	for i := 0; i < len(line); i++ {
		c := line[i]
		switch {
		case escaped:
			cur.WriteByte(c)
			escaped = false
		case quote == '\'':
			if c == '\'' {
				quote = 0
			} else {
				cur.WriteByte(c)
			}
		case quote == '"':
			switch {
			case c == '"':
				quote = 0
			case c == '\\' && i+1 < len(line) && strings.IndexByte("$`\"\\", line[i+1]) >= 0:
				i++
				cur.WriteByte(line[i])
			default:
				cur.WriteByte(c)
			}
		case c == ' ' || c == '\t' || c == '\n':
			if inWord {
				words = append(words, cur.String())
				cur.Reset()
				inWord = false
			}
			continue
		case c == '\\':
			escaped = true
		case c == '\'' || c == '"':
			quote = c
		default:
			cur.WriteByte(c)
		}
		if !inWord {
			inWord, start = true, i
		}
	}
	if !inWord {
		return append(words, ""), "", 0
	}
	return append(words, cur.String()), line[start:], quote
}

// bashReplacement quotes a candidate as the user started the word, and
// returns the part that replaces bash's current word: our word minus what
// bash split off in front of it. Complete candidates end with a space.
func bashReplacement(c, raw, bashCur string, quote byte) string {
	final := !partial(c)
	var q string
	switch quote {
	case '\'':
		q = "'" + c
		if final {
			q += "' "
		}
	case '"':
		q = `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "$", `\$`, "`", "\\`").Replace(c)
		if final {
			q += `" `
		}
	default:
		var b strings.Builder
		for _, r := range c {
			if strings.ContainsRune(" \t'\"\\$`&|;<>()[]{}*?!#~", r) {
				b.WriteByte('\\')
			}
			b.WriteRune(r)
		}
		q = b.String()
		if final {
			q += " "
		}
	}
	offset := len(raw) - len(bashCur)
	if offset < 0 || offset > len(q) || !strings.EqualFold(q[:offset], raw[:offset]) {
		return ""
	}
	return q[offset:]
}

const bashScript = `# wtf completion for bash: eval "$(wtf completion bash)"
_wtf_complete() {
    local line
    COMPREPLY=()
    while IFS= read -r line; do
        if [[ $line == ":files" ]]; then
            compopt -o default 2>/dev/null
            COMPREPLY=()
            return
        fi
        COMPREPLY+=("$line")
    done < <("${COMP_WORDS[0]}" __complete bash "${COMP_LINE:0:COMP_POINT}" "${COMP_WORDS[COMP_CWORD]}" 2>/dev/null)
}
complete -o nospace -F _wtf_complete wtf wtf.exe
`

const zshScript = `#compdef wtf
# wtf completion for zsh: source <(wtf completion zsh)
_wtf() {
    local -a out partial final
    local line
    out=("${(@f)$(${words[1]} __complete zsh "${(@Q)words[2,CURRENT]}" 2>/dev/null)}")
    if [[ ${out[1]} == ":files" ]]; then
        _files
        return
    fi
    for line in "${out[@]}"; do
        [[ -z $line ]] && continue
        if [[ $line == */ || $line == *= ]]; then
            partial+=("$line")
        else
            final+=("$line")
        fi
    done
    (( ${#partial} )) && compadd -S '' -- "${partial[@]}"
    (( ${#final} )) && compadd -- "${final[@]}"
}
compdef _wtf wtf
`

var powershellScript = strings.ReplaceAll(`# wtf completion for PowerShell: wtf completion powershell | Out-String | Invoke-Expression

# The completions for the word before the cursor, from "wtf __complete".
function global:Get-WtfCompletion($commandAst, [int]$cursor, [string]$wordToComplete) {
    $words = @()
    foreach ($element in @($commandAst.CommandElements | Select-Object -Skip 1)) {
        if ($element.Extent.StartOffset -ge $cursor) { break }
        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $words += 'w:' + $element.Value
        } else {
            $words += 'w:' + $element.Extent.Text
        }
    }
    if ($wordToComplete -eq '') { $words += 'w:' }
    $command = $commandAst.CommandElements[0].Extent.Text
    $lines = @(& $command __complete powershell @words 2>$null)
    if ($lines.Count -gt 0 -and $lines[0] -eq ':files') { return }
    foreach ($line in $lines) {
        if ($line -eq '') { continue }
        $text = $line
        if ($line -match '[\s''"BACKTICK$&(){}@;,|<>#]') {
            $text = "'" + $line.Replace("'", "''") + "'"
        }
        # A complete term ends with a space, ready for the next argument;
        # "Garage/" and "Colour=" continue.
        if (-not ($line.EndsWith('/') -or $line.EndsWith('='))) {
            $text += ' '
        }
        [System.Management.Automation.CompletionResult]::new($text, $line, 'ParameterValue', $line)
    }
}

# The wtf command the cursor is in, or $null.
function global:Get-WtfCommandAst([string]$line, [int]$cursor) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$null)
    $command = $ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.CommandAst] -and $a.Extent.StartOffset -le $cursor
        }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -Last 1
    if ($command -and $command.GetCommandName() -match '(^|[\\/])wtf(\.exe)?$') { return $command }
}

Register-ArgumentCompleter -Native -CommandName 'wtf', 'wtf.exe' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Get-WtfCompletion $commandAst $cursorPosition $wordToComplete
}

# PowerShell never asks a native completer about a bare "-" or "--" (it
# takes them for its own parameter syntax), so TabExpansion2, which all
# completion goes through, fills in wtf's flags for them.
if (-not $global:WtfTabExpansion2) {
    $global:WtfTabExpansion2 = (Get-Command TabExpansion2 -CommandType Function).ScriptBlock
}
function global:TabExpansion2 {
    [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
    param(
        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 0)]
        [string]$inputScript,
        [Parameter(ParameterSetName = 'ScriptInputSet', Position = 1)]
        [int]$cursorColumn = $inputScript.Length,
        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 0)]
        [System.Management.Automation.Language.Ast]$ast,
        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 1)]
        [System.Management.Automation.Language.Token[]]$tokens,
        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 2)]
        [System.Management.Automation.Language.IScriptPosition]$positionOfCursor,
        [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
        [Parameter(ParameterSetName = 'AstInputSet', Position = 3)]
        [Hashtable]$options = $null
    )
    $result = & $global:WtfTabExpansion2 @PSBoundParameters
    if ($result -and $result.CompletionMatches.Count -gt 0) { return $result }
    if ($PSCmdlet.ParameterSetName -eq 'AstInputSet') {
        $inputScript = $ast.Extent.Text
        $cursorColumn = $positionOfCursor.Offset
    }
    $word = [regex]::Match($inputScript.Substring(0, $cursorColumn), '\S*$').Value
    if ($word -ne '-' -and $word -ne '--') { return $result }
    $command = Get-WtfCommandAst $inputScript $cursorColumn
    if (-not $command) { return $result }
    $found = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    foreach ($m in @(Get-WtfCompletion $command $cursorColumn $word)) { $found.Add($m) }
    return [System.Management.Automation.CommandCompletion]::new($found, -1, $cursorColumn - $word.Length, $word.Length)
}

# Tab works as in bash for wtf: it completes as far as all candidates agree,
# and a second Tab lists them (PSReadLine's Complete). Tab keeps its own
# binding for other commands.
if (Get-Module PSReadLine) {
    $bound = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq 'Tab' } | Select-Object -First 1
    if (-not $bound -or $bound.Function -ne 'WtfTab') {
        $previous = 'TabCompleteNext'
        if ($bound -and [Microsoft.PowerShell.PSConsoleReadLine].GetMethod($bound.Function)) {
            $previous = $bound.Function
        }
        $global:WtfPreviousTab = [Microsoft.PowerShell.PSConsoleReadLine].GetMethod($previous)
    }
    Set-PSReadLineKeyHandler -Key Tab -BriefDescription WtfTab -Description 'Tab: as in bash for wtf, as before for other commands' -ScriptBlock {
        param($key, $arg)
        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if (Get-WtfCommandAst $line $cursor) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Complete($key, $arg)
        } else {
            $global:WtfPreviousTab.Invoke($null, @($key, $arg))
        }
    }
}
`, "BACKTICK", "`")
