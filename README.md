# UnrealMcpProxy
An MCP proxy that stays alive even if Unreal Engine editor crashes or recompiles. (Windows)

In theory, you can use it to proxy any MCP but I built it to help myself with UE development.

## Dependencies

- If you can compile an Unreal Engine project, you already have all the dependencies.

## License

Public Domain

## Usage

### Claude

```
{
    "unreal-mcp": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
               "path\\to\\file\\Start-UnrealMcpProxy.ps1", "-Upstream", "http://127.0.0.1:8000/mcp"]
    }
}
```

## Disclaimer

Prototype drafted by Opus 5.5 (AI), then was debugged and stripped into its minimum viable form by me (human). If you have no AI policy, you may wanna skip this one. Don't ship it to production, it's a development tool. If it becomes sentient and invades your country, it's not my fault.

## Contribution

Please submit a PR to improve this README with instructions for other agent tools.
