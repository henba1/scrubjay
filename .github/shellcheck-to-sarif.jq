# shellcheck's JSON -> SARIF 2.1.0, so GitHub code scanning can ingest it.
#
#   shellcheck -f json1 ... | jq -f .github/shellcheck-to-sarif.jq > shellcheck.sarif
#
# Why a jq script and not an off-the-shelf action: this repo installs SessionStart hooks and
# writes ~/.ssh/config, so CI deliberately avoids third-party actions (see lint.yml). shellcheck
# has no native SARIF writer, and this mapping is short enough that owning it beats the supply
# chain.
#
# An EMPTY result set is a valid and necessary upload: the "require code scanning results" ruleset
# rule needs an *analysis* to exist for the commit, not alerts. Clean runs must still publish.

def sarif_level:
  # shellcheck: error | warning | info | style   ->   SARIF: error | warning | note
  if   . == "error"   then "error"
  elif . == "warning" then "warning"
  else "note" end;

. as $root
# One rule object per distinct SCxxxx seen. GitHub keys alert identity off ruleId, so the id is
# the shellcheck code itself — nothing invented here, and it stays stable across runs.
| ([ $root.comments[] | "SC\(.code)" ] | unique) as $ids
| {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [ {
      tool: { driver: {
        name: "ShellCheck",
        informationUri: "https://www.shellcheck.net",
        rules: [ $ids[] | {
          id: .,
          name: .,
          helpUri: "https://www.shellcheck.net/wiki/\(.)",
          shortDescription: { text: . },
          fullDescription: { text: "See https://www.shellcheck.net/wiki/\(.)" },
          properties: { tags: [ "shell", "shellcheck" ] }
        } ]
      } },
      results: [ $root.comments[] | ("SC\(.code)") as $rid | {
        ruleId: $rid,
        # bound above on purpose: inside `$ids | index(...)` the dot is the id array, not the
        # comment, so an inline "SC\(.code)" there would index an array with a string.
        ruleIndex: ($ids | index($rid)),
        level: (.level | sarif_level),
        message: { text: "\(.message) (SC\(.code): https://www.shellcheck.net/wiki/SC\(.code))" },
        locations: [ { physicalLocation: {
          artifactLocation: { uri: .file },
          region: {
            startLine: (.line // 1),
            startColumn: (.column // 1),
            endLine: (.endLine // .line // 1),
            # SARIF endColumn is exclusive and must sit past startColumn; shellcheck reports the
            # two equal on zero-width spans, which GitHub rejects outright.
            endColumn: ([ (.endColumn // 1), ((.column // 1) + 1) ] | max)
          }
        } } ]
      } ]
    } ]
  }
