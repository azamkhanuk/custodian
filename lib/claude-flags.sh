# The Claude Code flags the runner depends on. Doctor checks the installed CLI for each one.
# 2.1.295 fixed --tools and --restricted not applying to built-in tools that register after launch.
CLAUDE_CODE_FLOOR=2.1.295
CLAUDE_FLAGS=(
  --safe-mode --restricted --tools --allowedTools --add-dir --strict-mcp-config
  --permission-mode --permission-prompts --model --json-schema --output-format --verbose --no-session-persistence
)
