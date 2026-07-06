# nvim-dap-react-native

React Native Hermes attach support for `nvim-dap`.

React Native DevTools is the official supported debugger for React Native. This plugin is a Neovim DAP bridge to the React Native / Hermes CDP endpoint. It is not an official React Native debugging frontend.

## What It Does

This plugin handles VS Code-style `reactnativedirect` attach configurations from
`dap.configurations` or `.vscode/launch.json`:

Full supported attach schema:

```jsonc
{
  "type": "reactnativedirect",
  "request": "attach",
  "name": "Attach React Native Hermes",
  "cwd": "${workspaceFolder}",
  "address": "127.0.0.1",
  "port": 8081,
  "sourceMaps": true,
  "sourceMapPathOverrides": {
    "/[metro-project]/*": "${workspaceFolder}/*",
  },
  "skipFiles": [
    "<node_internals>/**",
    "node_modules/**",
    "**/node_modules/undici/**",
    "**/node_modules/typescript/**",
    "**/node_modules/@expo/**",
    "**/*.bundle.js",
    "**/*.min.js",
  ],
}
```

Defaults are the values shown above. `sourceMapPathOverrides` and `skipFiles` are optional.

Related VS Code React Native Tools docs:

- [Hermes engine and direct debugging](https://github.com/microsoft/vscode-react-native#hermes-engine-and-direct-debugging-recommended)
- [Debugger configuration properties](https://github.com/microsoft/vscode-react-native#debugger-configuration-properties)

## Requirements

- Neovim with `nvim-dap`
- [`vscode-js-debug` configured as `pwa-node`](https://codeberg.org/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation#javascript)
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
```

With lazy.nvim:

```lua
{
  "AkisArou/nvim-dap-react-native",
  build = "npm ci",
}
```

## Usage

Use a React Native Tools-style `reactnativedirect` attach configuration:

Project-specific values belong in `dap.configurations` or `launch.json`. The plugin also reads `REACT_NATIVE_PACKAGER_HOSTNAME` and `RCT_METRO_PORT` when `address` or `port` are not set.

```lua
local dap = require("dap")

-- Pass the same vscode-js-debug adapter definition you use for pwa-node.
dap.adapters.reactnativedirect =
  require("dap-react-native").create_adapter(js_debug_adapter_opts)

for _, language in ipairs({
  "javascript",
  "javascriptreact",
  "typescript",
  "typescriptreact",
}) do
  dap.configurations[language] = dap.configurations[language] or {}
  table.insert(dap.configurations[language], {
    type = "reactnativedirect",
    request = "attach",
    name = "React Native: Attach Hermes",
    cwd = "${workspaceFolder}",
  })
end
```

The same JSON shape can live in `.vscode/launch.json` if you prefer to reuse VS Code-style project config.

`request = "launch"` is intentionally not implemented yet. Start Metro and the app yourself, then attach.

You can also attach directly from a keymap:

```lua
vim.keymap.set("n", "<leader>dn", function()
  require("dap-react-native").attach()
end)
```
