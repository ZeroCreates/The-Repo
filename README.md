# Rift Script Library

This project includes a self-hosted Node.js catalog and file server for Rift ComputerCraft scripts. ComputerCraft clients download from this server instead of GitHub. The server reads the catalog and script files from this project directory; it does not need external Node.js packages.

## Start the host

Install Node.js 20.6 or newer on the machine that will host the scripts. Create your local environment file from the example:

```powershell
Copy-Item .env.example .env
```

Edit `.env` if needed, then start the host from this project directory:

```powershell
npm start
```

The website is available at `http://localhost:3000/`. The catalog API is at `/api/catalog`, the launcher has a dedicated `/launcher` endpoint, `/api/scripts` lists all ComputerCraft Lua scripts, and scripts are served at their project-relative paths, such as `/computercraft/apps/calculator.lua` or `/computercraft/server/rift-server.lua`. KubeJS scripts are not exposed.

The `.env` file controls `HOST` and `PORT`; the example binds to `0.0.0.0:3000`. `.env` is git-ignored and should hold machine-specific settings. To keep the host running, use a process manager or run it as a service. For public internet access, put it behind a TLS-enabled reverse proxy.

## Connect ComputerCraft

The Lua clients default to `http://127.0.0.1:3000/`, which works when the Minecraft/ComputerCraft server and this Node server run on the same machine. If they run on different machines, change `HOST_BASE_URL` in each of these files to the Node server's reachable address, including the trailing slash:

- `launcher.lua`
- `computercraft/system/settings.lua`
- `computercraft/system/app-downloader.lua`
- `computercraft/apps/casino.lua`
- `computercraft/apps/market-update.lua`

For example: `local HOST_BASE_URL = "http://192.168.1.20:3000/"`. Also enable the ComputerCraft HTTP API and allow the host address in the Minecraft server's ComputerCraft HTTP settings. If using a reverse proxy, set the URL to its HTTPS address instead.

To bootstrap a new ComputerCraft computer after choosing the correct address, run `wget http://127.0.0.1:3000/launcher launcher.lua` (replace the address if needed), then run `launcher.lua`.

## Add or update apps

Edit `app-catalog.json` to change the app catalog entries. Each `source` is a project-relative Lua path served by the host. All Lua files under `computercraft/` and the launcher are publicly served; other project files, including KubeJS scripts, are not exposed.