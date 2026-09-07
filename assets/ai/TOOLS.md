# TOOLS.md

The app can expose these tool contracts to the model:

- GitHub read file
- GitHub write file (requires user confirmation)
- GitHub list issues
- Local read file
- Local write file (requires user confirmation)
- Local list files
- Calculator
- Date/time
- System information
- Clipboard copy (requires user confirmation)
- Web search

Tool calls use the fixed [[TOOL_BLOCK]] text syntax implemented by ToolParser. Tool output is injected back into the conversation as runtime context. The model must never claim a tool ran unless the application returned a result.
