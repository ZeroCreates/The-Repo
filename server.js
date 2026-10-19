"use strict";

const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");

const ROOT = __dirname;
const PUBLIC_ROOT = path.join(ROOT, "public");
try {
    process.loadEnvFile(path.join(ROOT, ".env"));
} catch (error) {
    if (error.code !== "ENOENT") throw error;
}
const HOST = process.env.HOST || "0.0.0.0";
const PORT = Number(process.env.PORT || 3000);
const SCRIPT_PATH = /^(?:launcher\.lua|computercraft\/.+\.lua)$/i;

function respond(response, status, body, contentType) {
    response.writeHead(status, {
        "Content-Type": contentType,
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "no-cache",
    });
    response.end(body);
}

function isInside(directory, candidate) {
    return candidate.startsWith(directory + path.sep);
}

async function handleRequest(request, response) {
    if (request.method !== "GET" && request.method !== "HEAD") {
        response.setHeader("Allow", "GET, HEAD");
        respond(response, 405, "Method not allowed", "text/plain; charset=utf-8");
        return;
    }

    let requestPath;
    try {
        requestPath = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    } catch {
        respond(response, 400, "Bad request", "text/plain; charset=utf-8");
        return;
    }

    if (requestPath === "/launcher") requestPath = "/launcher.lua";

    if (requestPath === "/" || requestPath === "/index.html") {
        const page = await fs.readFile(path.join(PUBLIC_ROOT, "index.html"));
        respond(response, 200, request.method === "HEAD" ? "" : page, "text/html; charset=utf-8");
        return;
    }

    if (requestPath === "/api/health") {
        respond(response, 200, JSON.stringify({ status: "ok" }), "application/json; charset=utf-8");
        return;
    }

    if (requestPath === "/api/scripts") {
        const scripts = await listComputerCraftScripts();
        respond(response, 200, request.method === "HEAD" ? "" : JSON.stringify(scripts), "application/json; charset=utf-8");
        return;
    }

    if (requestPath === "/api/catalog" || requestPath === "/app-catalog.json") {
        const contents = await fs.readFile(path.join(ROOT, "app-catalog.json"), "utf8");
        JSON.parse(contents);
        respond(response, 200, request.method === "HEAD" ? "" : contents, "application/json; charset=utf-8");
        return;
    }

    const relativePath = requestPath.replace(/^\//, "");
    if (relativePath.includes("\\") || relativePath.split("/").includes("..")
        || !SCRIPT_PATH.test(relativePath)) {
        respond(response, 404, "Not found", "text/plain; charset=utf-8");
        return;
    }

    const filePath = path.resolve(ROOT, relativePath);
    if (!isInside(ROOT, filePath)) {
        respond(response, 404, "Not found", "text/plain; charset=utf-8");
        return;
    }

    try {
        const contents = await fs.readFile(filePath);
        respond(response, 200, request.method === "HEAD" ? "" : contents, "text/plain; charset=utf-8");
    } catch (error) {
        if (error.code === "ENOENT" || error.code === "EISDIR") {
            respond(response, 404, "Not found", "text/plain; charset=utf-8");
            return;
        }
        throw error;
    }
}

async function listComputerCraftScripts(directory = path.join(ROOT, "computercraft"), relativeDirectory = "computercraft") {
    const entries = await fs.readdir(directory, { withFileTypes: true });
    const scripts = [];
    for (const entry of entries) {
        const relativePath = path.posix.join(relativeDirectory, entry.name);
        const fullPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            scripts.push(...await listComputerCraftScripts(fullPath, relativePath));
        } else if (entry.isFile() && entry.name.toLowerCase().endsWith(".lua")) {
            scripts.push(relativePath);
        }
    }
    return scripts.sort((first, second) => first.localeCompare(second));
}

const server = http.createServer((request, response) => {
    handleRequest(request, response).catch((error) => {
        console.error(error);
        if (!response.headersSent) {
            respond(response, 500, "Internal server error", "text/plain; charset=utf-8");
        } else {
            response.destroy();
        }
    });
});

server.listen(PORT, HOST, () => {
    console.log(`Rift Script Library listening on http://${HOST}:${PORT}`);
});