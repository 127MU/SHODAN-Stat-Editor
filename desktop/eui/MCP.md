# MCP

Open Settings, enable MCP, and copy the connection configuration into a client
that supports Streamable HTTP with custom headers. The application must remain
open. The loopback port and bearer token change each session; restarting or
turning the switch off closes the endpoint. Do not publish the copied token.

`tools/list` is generated from the running Lua bridge, including every existing
backend function. Backend tools use an `args` array of positional arguments;
each tool describes their order. For example:

```json
{"name":"shodan_items","arguments":{"args":["Primary",""]}}
```

Select an item with `shodan_select`, inspect `shodan_rows`, then change numeric
values with `shodan_set`. Use `shodan_choices` and `shodan_choose` to select
projectiles, explosions, and status effects. IDs are identifiers from these
queries, not list positions. `Helldiver` lists the original player record.
Changing a projectile retains the original editor's behavior: the new shot
uses its source weapon's projectile statistics; the upper rows still describe
the original shot. Edit the source weapon to tune the substituted shot.

Armor, equipment and global presets, preview, merge, install and restore use
the existing editor paths. Install and restore require the game to be closed.
`shodan_mods_*` provides ZIP import, metadata and options, switches, removal,
and merged ZIP export. Mod tools require enabling the hidden feature in the
UI first (equipment search `mu7`, then confirmation). The switch is never
silently enabled by a client.

Debug tools expose the interface inventory, Lua stack and memory, backend
status, public properties, current-row validation, recent MCP call outcomes,
and bounded reads of files in the editor's Logs folder. No Lua evaluation,
process injection, or arbitrary shell command endpoint is provided.
Binary Lua strings are represented by `{"$base64":"..."}` in both directions.
Requests run serially with UI operations against the same Lua state.

Native integration checks (using an isolated profile, without game writes):

```powershell
python tests/test_mcp_live.py --exe "<release>/SHODAN 数值编辑器.exe" --output "<new QA folder>"
python tests/test_weapon_output.py --runtime-dir "<release>" --output "<new QA folder>"
```

The output preparation test requires `lupa` with LuaJIT and access to a matching
local game data installation. It replaces the disk writer, verifies actual
sealed damage/projectile/entity output, and tests repeat installation against
an already modified working snapshot.
