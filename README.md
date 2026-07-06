# nvim-dap-react-native

React Native Hermes attach support for `nvim-dap`.

React Native DevTools is the official supported debugger for React Native. This plugin is a Neovim DAP bridge to the React Native / Hermes CDP endpoint. It is not an official React Native debugging frontend.

## What It Does

This plugin handles VS Code-style `reactnativedirect` attach configurations from
`.vscode/launch.json` or `dap.configurations`:

```jsonc
{
  "type": "reactnativedirect",
  "request": "attach",
  "name": "Attach React Native Hermes",
  "cwd": "${workspaceFolder}/apps/mobile"
}
```

Internally it runs:

```text
nvim-dap
  -> vscode-js-debug pwa-node
  -> local Hermes CDP proxy
  -> Metro / React Native Hermes websocket
```

The proxy is used instead of connecting `vscode-js-debug` directly to Metro. It injects the websocket `Origin` header Metro expects and vendors the small Hermes CDP message handling used by `microsoft/vscode-react-native`.

It does not configure your generic JavaScript debugging setup. Keep `vscode-js-debug`, browser attach configs, Node configs, and any `dap.ext.vscode` JSON parsing customizations in your normal `dap.lua`.

## Requirements

- Neovim with `nvim-dap`
- `vscode-js-debug` configured as `pwa-node`
- Node.js 20+
- Metro running and reachable
- React Native app running with Hermes

Install the Node proxy dependencies once. Plugin managers should run this as the build hook.

```lua
{
  "AkisArou/nvim-dap-react-native",
  build = "npm ci",
  config = function()
    require("dap-react-native").setup()
  end,
}
```

For this local checkout:

```sh
cd ~/Projects/nvim-dap-react-native
npm ci
```

## Setup

If you are using this repository as a local checkout, put the plugin on Neovim's runtime path:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/Projects/nvim-dap-react-native"))
require("dap-react-native").setup()
```

Keep your generic JavaScript adapter setup outside this plugin. This plugin expects `pwa-node` to already exist when you start the session, for example through `vscode-js-debug` / Mason / your existing `dap.lua`.

For React Native Hermes attach, only `pwa-node` is required. Configure `pwa-chrome` separately only if you also debug browser apps.

## Configuration

Defaults:

```lua
require("dap-react-native").setup({
  react_native_type = "reactnativedirect",
  adapter = "pwa-node",

  metro_host = "127.0.0.1",
  metro_port = 8081,

  proxy = {
    host = "127.0.0.1",
    node_command = "node",
    script_path = "<plugin>/scripts/react-native-hermes-cdp-proxy.js",
    log = false,
    start_timeout_ms = 5000,
  },

  source_maps = true,
  resolve_source_map_locations = {
    "**",
    "!**/node_modules/!(expo)/**",
  },
  setup_pause_stop_fix = true,

  skip_files = {
    "<node_internals>/**",
    "node_modules/**",
    "**/node_modules/undici/**",
    "**/node_modules/typescript/**",
    "**/node_modules/@expo/**",
    "**/*.bundle.js",
    "**/*.min.js",
  },
})
```

Per-configuration `address` and `port` are treated like upstream `reactnativedirect` options and override the Metro host/port for that debug config.

The plugin also honors `REACT_NATIVE_PACKAGER_HOSTNAME` and `RCT_METRO_PORT` when no host or port is set in the debug config or setup options.

## Launch JSON

Use your normal `dap.ext.vscode` flow. Current `nvim-dap` reads `.vscode/launch.json` automatically on demand, so `dap.ext.vscode.load_launchjs()` and `type_to_filetypes` mappings are not needed for this plugin.

```jsonc
{
  "type": "reactnativedirect",
  "request": "attach",
  "name": "PRM: Attach Agent",
  "cwd": "${workspaceFolder}/apps/client/assistant-prm-airport/agent"
}
```

`request = "launch"` is intentionally not implemented yet. Start Metro and the app yourself, then attach.

If you do not want to use `launch.json`, define the same configuration in `dap.configurations`:

```lua
require("dap").configurations.typescriptreact = {
  {
    type = "reactnativedirect",
    request = "attach",
    name = "React Native: Attach Hermes",
    cwd = "${workspaceFolder}/apps/client/assistant-prm-airport/agent",
  },
}
```

For a keymap or command, you can also bypass configuration selection:

```lua
vim.keymap.set("n", "<leader>dn", function()
  require("dap-react-native").attach({
    cwd = vim.fn.getcwd(),
  })
end)
```

## Notes

The plugin starts one local proxy process per attach session and stops it when the DAP session exits or terminates.

By default the Lua module runs `scripts/react-native-hermes-cdp-proxy.js`, which requires the plugin directory's `node_modules` from `npm ci`.

If multiple Hermes targets are available, the plugin asks you to pick one through `nvim-dap`'s UI picker.
