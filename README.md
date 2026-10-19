# Rift Script Library

This project includes a self-hosted Node.js catalog and file server for Rift ComputerCraft scripts. ComputerCraft clients download from this server instead of GitHub. The server reads the catalog and script files from this project directory; it does not need external Node.js packages.

## Start the host

Install Node.js 20.12 or newer on the machine that will host the scripts. The server starts with default settings (`0.0.0.0:3000`) even if no `.env` file exists. To customize them, create a local environment file from the example:

```powershell
Copy-Item .env.example .env
```

Edit `.env` if needed, then start the host from this project directory:

```powershell
npm start
```

The website is available at `https://rift.zerocreates.org/`. The catalog API is at `/api/catalog`, the launcher has a dedicated `/launcher` endpoint, `/api/scripts` lists all ComputerCraft Lua scripts, and scripts are served at their project-relative paths, such as `/computercraft/apps/calculator.lua` or `/computercraft/server/rift-server.lua`. KubeJS scripts are not exposed. For local development, the Node server is available at `http://localhost:3000/`.

The optional `.env` file controls `HOST` and `PORT`; the example binds to `0.0.0.0:3000`. `.env` is git-ignored and should hold machine-specific settings. To keep the host running, use a process manager or run it as a service. For public internet access, put it behind a TLS-enabled reverse proxy.

## Manage apps

Open `/manager` on the hosted site. Set `MANAGER_PASSWORD` in the host's `.env` to a strong, unique password, then restart the server. The manager can add apps, upload replacement Lua files, update descriptions and versions, and remove catalog apps and their files. It also allows versioned updates to scripts under `computercraft/server` and `computercraft/system`; system versions are saved in the app catalog, while server versions are stored in `script-versions.json`. Server/system scripts cannot be removed from the manager. Keep manager access behind HTTPS because the password is sent to the host for authenticated requests.

## Connect ComputerCraft

The Lua clients fetch from `https://rift.zerocreates.org/`. If you self-host at a different address, change `HOST_BASE_URL` in each of these files, including the trailing slash:

- `launcher.lua`
- `computercraft/system/settings.lua`
- `computercraft/system/app-downloader.lua`
- `computercraft/apps/casino.lua`
- `computercraft/apps/market-update.lua`

For example: `local HOST_BASE_URL = "https://scripts.example.com/"`. Also enable the ComputerCraft HTTP API and allow the host address in the Minecraft server's ComputerCraft HTTP settings.

To bootstrap a new ComputerCraft computer, run `wget https://rift.zerocreates.org/launcher launcher.lua`, then run `launcher.lua`.

Cloud Catcher is installed with the system apps. Start it from System Settings using the **CLOUD** button and enter the 32-character connection code. It runs in the background and mirrors the launcher and active program screen; remote keyboard and mouse input control the active UI. File hosting is limited to the active profile home.

## Add or update apps

Edit `app-catalog.json` to change the app catalog entries. Each `source` is a project-relative Lua path served by the host. All Lua files under `computercraft/` and the launcher are publicly served; other project files, including KubeJS scripts, are not exposed.