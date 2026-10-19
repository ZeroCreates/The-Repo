"use strict";

const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");

const ROOT = __dirname;
const PUBLIC_ROOT = path.join(ROOT, "public");
try {
    process.loadEnvFile(path.join(ROOT, ".env"));
} catch (error) {
    if (error.code !== "ENOENT") throw error;
}
const HOST = process.env.HOST || "0.0.0.0";
const PORT = Number(process.env.PORT || 3000);
const MANAGER_PASSWORD = process.env.MANAGER_PASSWORD || "";
const MAX_SCRIPT_BYTES = 1024 * 1024;
const MAX_REQUEST_BYTES = MAX_SCRIPT_BYTES * 6 + 16 * 1024;
const SCRIPT_PATH = /^(?:launcher\.lua|computercraft\/.+\.lua)$/i;
const APP_FILE_NAME = /^[a-z0-9][a-z0-9_-]*\.lua$/;
const APP_VERSION = /^\d+\.\d+\.\d+$/;

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
    if (!["GET", "HEAD", "POST", "PUT", "DELETE"].includes(request.method)) {
        response.setHeader("Allow", "GET, HEAD, POST, PUT, DELETE");
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

    if (requestPath === "/manager" || requestPath === "/manager/") {
        if (request.method !== "GET" && request.method !== "HEAD") {
            response.setHeader("Allow", "GET, HEAD");
            respond(response, 405, "Method not allowed", "text/plain; charset=utf-8");
            return;
        }
        const page = await fs.readFile(path.join(PUBLIC_ROOT, "manager.html"));
        respond(response, 200, request.method === "HEAD" ? "" : page, "text/html; charset=utf-8");
        return;
    }

    if (requestPath.startsWith("/api/manager/")) {
        if (!MANAGER_PASSWORD) {
            sendJson(response, 503, { error: "Manager is disabled. Set MANAGER_PASSWORD in .env." });
            return;
        }
        if (!isAuthorizedManager(request)) {
            sendJson(response, 401, { error: "Manager password required." });
            return;
        }
        await handleManagerApi(request, response, requestPath);
        return;
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
        response.setHeader("Allow", "GET, HEAD");
        respond(response, 405, "Method not allowed", "text/plain; charset=utf-8");
        return;
    }

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

function sendJson(response, status, value) {
    respond(response, status, JSON.stringify(value), "application/json; charset=utf-8");
}

function isAuthorizedManager(request) {
    const authorization = request.headers.authorization || "";
    if (!authorization.startsWith("Bearer ")) return false;
    const supplied = Buffer.from(authorization.slice(7));
    const expected = Buffer.from(MANAGER_PASSWORD);
    return supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
}

async function readJsonBody(request) {
    const chunks = [];
    let size = 0;
    for await (const chunk of request) {
        size += chunk.length;
        if (size > MAX_REQUEST_BYTES) {
            const error = new Error("Request body is too large.");
            error.statusCode = 413;
            throw error;
        }
        chunks.push(chunk);
    }
    try {
        return JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
        const error = new Error("Request body must be valid JSON.");
        error.statusCode = 400;
        throw error;
    }
}

function validateAppFields(body, allowMissingContents = false) {
    if (!body || typeof body !== "object" || Array.isArray(body)) {
        return "Request must contain an app object.";
    }
    if (typeof body.name !== "string" || !body.name.trim() || body.name.trim().length > 80) {
        return "App name must contain 1 to 80 characters.";
    }
    if (typeof body.description !== "string" || !body.description.trim() || body.description.trim().length > 240) {
        return "Description must contain 1 to 240 characters.";
    }
    if (typeof body.version !== "string" || !APP_VERSION.test(body.version)) {
        return "Version must use major.minor.patch format, such as 1.0.0.";
    }
    if (!allowMissingContents || body.contents !== undefined) {
        if (typeof body.contents !== "string" || !body.contents.trim()) {
            return "Upload a non-empty Lua script.";
        }
        if (Buffer.byteLength(body.contents, "utf8") > MAX_SCRIPT_BYTES) {
            return "Lua scripts must be 1 MB or smaller.";
        }
    }
    return null;
}

async function readCatalog() {
    const contents = await fs.readFile(path.join(ROOT, "app-catalog.json"), "utf8");
    const catalog = JSON.parse(contents);
    if (!Array.isArray(catalog)) throw new Error("App catalog must be a JSON array.");
    return catalog;
}

async function writeAtomically(filePath, contents) {
    const temporaryPath = `${filePath}.${crypto.randomUUID()}.tmp`;
    try {
        await fs.writeFile(temporaryPath, contents, { encoding: "utf8", flag: "wx" });
        await fs.rename(temporaryPath, filePath);
    } catch (error) {
        await fs.rm(temporaryPath, { force: true }).catch(() => {});
        throw error;
    }
}

async function writeCatalog(catalog) {
    await writeAtomically(path.join(ROOT, "app-catalog.json"), `${JSON.stringify(catalog, null, 2)}\n`);
}

function appFilePath(file) {
    return path.join(ROOT, "computercraft", "apps", file);
}

function isManagedApp(app) {
    return app && app.scope !== "system" && app.source === `computercraft/apps/${app.file}`
        && APP_FILE_NAME.test(app.file);
}

async function handleManagerApi(request, response, requestPath) {
    const collectionPath = "/api/manager/apps";
    if (requestPath === collectionPath && request.method === "GET") {
        const catalog = await readCatalog();
        sendJson(response, 200, catalog.filter(isManagedApp));
        return;
    }

    if (requestPath === collectionPath && request.method === "POST") {
        const body = await readJsonBody(request);
        const validationError = validateAppFields(body);
        if (validationError) {
            sendJson(response, 400, { error: validationError });
            return;
        }
        if (typeof body.file !== "string" || !APP_FILE_NAME.test(body.file)) {
            sendJson(response, 400, { error: "Filename must use lowercase letters, numbers, hyphens, or underscores and end in .lua." });
            return;
        }

        const catalog = await readCatalog();
        if (catalog.some((app) => app.file === body.file) || await fs.access(appFilePath(body.file)).then(() => true, () => false)) {
            sendJson(response, 409, { error: "That filename is already in use." });
            return;
        }

        const app = {
            name: body.name.trim(),
            source: `computercraft/apps/${body.file}`,
            file: body.file,
            version: body.version,
            description: body.description.trim(),
        };
        await writeAtomically(appFilePath(body.file), body.contents);
        try {
            await writeCatalog([...catalog, app]);
        } catch (error) {
            await fs.rm(appFilePath(body.file), { force: true });
            throw error;
        }
        sendJson(response, 201, app);
        return;
    }

    const encodedFile = requestPath.startsWith(`${collectionPath}/`)
        ? requestPath.slice(collectionPath.length + 1) : "";
    if (!encodedFile || encodedFile.includes("/")) {
        sendJson(response, 404, { error: "Manager endpoint not found." });
        return;
    }
    const file = encodedFile;
    if (!APP_FILE_NAME.test(file)) {
        sendJson(response, 400, { error: "Invalid app filename." });
        return;
    }

    const catalog = await readCatalog();
    const index = catalog.findIndex((app) => isManagedApp(app) && app.file === file);
    if (index === -1) {
        sendJson(response, 404, { error: "App not found." });
        return;
    }

    if (request.method === "PUT") {
        const body = await readJsonBody(request);
        const validationError = validateAppFields(body, true);
        if (validationError) {
            sendJson(response, 400, { error: validationError });
            return;
        }
        const updatedApp = {
            ...catalog[index],
            name: body.name.trim(),
            description: body.description.trim(),
            version: body.version,
        };
        if (body.contents !== undefined) {
            await writeAtomically(appFilePath(file), body.contents);
        }
        catalog[index] = updatedApp;
        await writeCatalog(catalog);
        sendJson(response, 200, updatedApp);
        return;
    }

    if (request.method === "DELETE") {
        const [removedApp] = catalog.splice(index, 1);
        await writeCatalog(catalog);
        await fs.rm(appFilePath(file), { force: true });
        sendJson(response, 200, { removed: removedApp.file });
        return;
    }

    response.setHeader("Allow", "GET, POST, PUT, DELETE");
    sendJson(response, 405, { error: "Method not allowed." });
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
            const status = error.statusCode || 500;
            const message = error.statusCode ? error.message : "Internal server error";
            respond(response, status, message, "text/plain; charset=utf-8");
        } else {
            response.destroy();
        }
    });
});

server.listen(PORT, HOST, () => {
    console.log(`Rift Script Library listening on http://${HOST}:${PORT}`);
});