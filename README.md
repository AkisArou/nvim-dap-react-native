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
  "cwd": "${workspaceFolder}/apps/mobile",
}
```

## Requirements

- Neovim with `nvim-dap`
- `vscode-js-debug` configured as `pwa-node`
- Node.js 20+

Install the Node proxy dependencies once. Plugin managers should run `npm ci` after installing or updating the plugin.

With `vim.pack`:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(event)
    if event.data.spec.name == "nvim-dap-react-native"
        and (event.data.kind == "install" or event.data.kind == "update") then
      vim.system({ "npm", "ci" }, { cwd = event.data.path }):wait()
    end
  end,
})

vim.pack.add({
  { src = "https://github.com/AkisArou/nvim-dap-react-native" },
})

require("dap-react-native").setup()
```

With lazy.nvim:

```lua
{
  "AkisArou/nvim-dap-react-native",
  build = "npm ci",
  config = function()
    require("dap-react-native").setup()
  end,
}
```

## Setup

Configure `pwa-node` in your normal DAP setup before using this plugin. `pwa-chrome` is not required for React Native.

Common options:

```lua
require("dap-react-native").setup({
  react_native_type = "reactnativedirect",
  adapter = "pwa-node",

  metro_host = "127.0.0.1",
  metro_port = 8081,

  source_maps = true,
  skip_files = {
    "<node_internals>/**",
    "node_modules/**",
  },
})
```

Per-config `address` / `port` override `metro_host` / `metro_port`. The plugin also reads `REACT_NATIVE_PACKAGER_HOSTNAME` and `RCT_METRO_PORT`.

## Usage

Current `nvim-dap` reads `.vscode/launch.json` automatically; `dap.ext.vscode.load_launchjs()` and `type_to_filetypes` mappings are not needed.

```jsonc
{
  "type": "reactnativedirect",
  "request": "attach",
  "name": "PRM: Attach Agent",
  "cwd": "${workspaceFolder}/apps/client/assistant-prm-airport/agent",
}
```

`request = "launch"` is intentionally not implemented yet. Start Metro and the app yourself, then attach.

You can also attach directly from a keymap:

```lua
vim.keymap.set("n", "<leader>dn", function()
  require("dap-react-native").attach()
end)
```
