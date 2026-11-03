"use strict";

const http = require("node:http");
const fsSync = require("node:fs");
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { Transform } = require("node:stream");
const { pipeline } = require("node:stream/promises");

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
const MAX_SHARED_FILE_BYTES = 50 * 1024 * 1024;
const SHARE_LIFETIME_MS = 24 * 60 * 60 * 1000;
const SHARE_DIRECTORY = path.join(ROOT, "uploads");
const SCRIPT_PATH = /^(?:launcher\.lua|computercraft\/.+\.lua)$/i;
const MANAGED_SCRIPT_PATH = /^computercraft\/(?:server|system)\/[a-z0-9_-]+\.lua$/i;
const APP_FILE_NAME = /^[a-z0-9][a-z0-9_-]*\.lua$/;
const APP_VERSION = /^\d+\.\d+\.\d+$/;
const SHARE_ID = /^[a-f0-9]{32}$/;
const SCRIPT_VERSIONS_PATH = path.join(ROOT, "script-versions.json");

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

    if (requestPath === "/api/share") {
        if (request.method !== "POST") {
            response.setHeader("Allow", "POST");
            sendJson(response, 405, { error: "Method not allowed." });
            return;
        }
        await handleShareUpload(request, response);
        return;
    }

    const sharedFileId = requestPath.startsWith("/share/")
        ? requestPath.slice("/share/".length) : "";
    if (sharedFileId) {
        if (request.method !== "GET" && request.method !== "HEAD") {
            response.setHeader("Allow", "GET, HEAD");
            respond(response, 405, "Method not allowed", "text/plain; charset=utf-8");
            return;
        }
        await handleSharedFile(request, response, sharedFileId);
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

function shareFilePath(id, extension) {
    return path.join(SHARE_DIRECTORY, `${id}.${extension}`);
}

async function handleShareUpload(request, response) {
    const contentLength = Number(request.headers["content-length"]);
    if (Number.isFinite(contentLength) && contentLength > MAX_SHARED_FILE_BYTES) {
        sendJson(response, 413, { error: "Files must be 50 MB or smaller." });
        request.resume();
        return;
    }

    await fs.mkdir(SHARE_DIRECTORY, { recursive: true });
    const id = crypto.randomBytes(16).toString("hex");
    const temporaryPath = shareFilePath(id, "tmp");
    let size = 0;
    const sizeLimit = new Transform({
        transform(chunk, encoding, callback) {
            size += chunk.length;
            if (size > MAX_SHARED_FILE_BYTES) {
                const error = new Error("Files must be 50 MB or smaller.");
                error.statusCode = 413;
                callback(error);
                return;
            }
            callback(null, chunk);
        },
    });

    try {
        await pipeline(request, sizeLimit, fsSync.createWriteStream(temporaryPath, { flags: "wx" }));
        if (size === 0) {
            const error = new Error("Upload a non-empty file.");
            error.statusCode = 400;
            throw error;
        }

        const suppliedName = request.headers["x-filename"];
        const fileName = (typeof suppliedName === "string" ? suppliedName : "shared-file")
            .replace(/[\\/]/g, "_").replace(/[\x00-\x1f\x7f]/g, "").trim().slice(0, 255) || "shared-file";
        const expiresAt = Date.now() + SHARE_LIFETIME_MS;
        await fs.rename(temporaryPath, shareFilePath(id, "data"));
        try {
            await writeAtomically(shareFilePath(id, "json"), JSON.stringify({ fileName, expiresAt }));
        } catch (error) {
            await fs.rm(shareFilePath(id, "data"), { force: true });
            throw error;
        }

        const forwardedProtocol = request.headers["x-forwarded-proto"];
        const protocol = typeof forwardedProtocol === "string" && ["http", "https"].includes(forwardedProtocol.split(",")[0].trim())
            ? forwardedProtocol.split(",")[0].trim() : "http";
        const origin = new URL(`${protocol}://${request.headers.host || "localhost"}`).origin;
        sendJson(response, 201, {
            id,
            url: `${origin}/share/${id}`,
            fileName,
            expiresAt: new Date(expiresAt).toISOString(),
        });
    } catch (error) {
        await fs.rm(temporaryPath, { force: true }).catch(() => {});
        throw error;
    }
}

async function handleSharedFile(request, response, id) {
    if (!SHARE_ID.test(id)) {
        respond(response, 404, "Not found", "text/plain; charset=utf-8");
        return;
    }

    const metadataPath = shareFilePath(id, "json");
    try {
        const metadata = JSON.parse(await fs.readFile(metadataPath, "utf8"));
        if (!Number.isFinite(metadata.expiresAt) || metadata.expiresAt <= Date.now()) {
            await Promise.all([
                fs.rm(shareFilePath(id, "data"), { force: true }),
                fs.rm(metadataPath, { force: true }),
            ]);
            respond(response, 404, "Not found", "text/plain; charset=utf-8");
            return;
        }

        const contents = await fs.readFile(shareFilePath(id, "data"));
        response.writeHead(200, {
            "Content-Type": "application/octet-stream",
            "Content-Length": contents.length,
            "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(metadata.fileName || "shared-file").replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)}`,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-cache",
        });
        response.end(request.method === "HEAD" ? undefined : contents);
    } catch (error) {
        if (error.code === "ENOENT" || error instanceof SyntaxError) {
            respond(response, 404, "Not found", "text/plain; charset=utf-8");
            return;
        }
        throw error;
    }
}

async function cleanupExpiredShares() {
    let entries;
    try {
        entries = await fs.readdir(SHARE_DIRECTORY, { withFileTypes: true });
    } catch (error) {
        if (error.code === "ENOENT") return;
        throw error;
    }

    const expiredFiles = entries
        .filter((entry) => entry.isFile() && SHARE_ID.test(entry.name.replace(/\.json$/, "")) && entry.name.endsWith(".json"));
    await Promise.all(expiredFiles.map(async (entry) => {
        const metadataPath = path.join(SHARE_DIRECTORY, entry.name);
        try {
            const metadata = JSON.parse(await fs.readFile(metadataPath, "utf8"));
            if (Number.isFinite(metadata.expiresAt) && metadata.expiresAt <= Date.now()) {
                const id = entry.name.slice(0, -".json".length);
                await Promise.all([
                    fs.rm(shareFilePath(id, "data"), { force: true }),
                    fs.rm(metadataPath, { force: true }),
                ]);
            }
        } catch (error) {
            if (error.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
        }
    }));
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

async function readScriptVersions() {
    try {
        const contents = await fs.readFile(SCRIPT_VERSIONS_PATH, "utf8");
        const versions = JSON.parse(contents);
        if (!versions || typeof versions !== "object" || Array.isArray(versions)) {
            throw new Error("Script versions must be a JSON object.");
        }
        return versions;
    } catch (error) {
        if (error.code === "ENOENT") return {};
        throw error;
    }
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
    if (requestPath === "/api/manager/scripts" && request.method === "GET") {
        const [catalog, versions, files] = await Promise.all([
            readCatalog(),
            readScriptVersions(),
            listComputerCraftScripts(),
        ]);
        const scripts = files.filter((source) => MANAGED_SCRIPT_PATH.test(source)).map((source) => {
            const app = catalog.find((entry) => entry.source === source);
            const file = path.posix.basename(source);
            return {
                source,
                file,
                group: source.split("/")[1],
                name: app ? app.name : file.replace(/\.lua$/i, ""),
                description: app ? app.description : "",
                version: app ? app.version : versions[source] || "",
            };
        });
        sendJson(response, 200, scripts);
        return;
    }

    const scriptSource = requestPath.startsWith("/api/manager/scripts/")
        ? requestPath.slice("/api/manager/scripts/".length) : "";
    if (scriptSource && MANAGED_SCRIPT_PATH.test(scriptSource) && request.method === "PUT") {
        const body = await readJsonBody(request);
        if (!body || typeof body !== "object" || Array.isArray(body)
            || typeof body.version !== "string" || !APP_VERSION.test(body.version)) {
            sendJson(response, 400, { error: "Version must use major.minor.patch format, such as 1.0.0." });
            return;
        }
        if (body.contents !== undefined && (typeof body.contents !== "string" || !body.contents.trim())) {
            sendJson(response, 400, { error: "Uploaded Lua script must not be empty." });
            return;
        }
        if (body.contents !== undefined && Buffer.byteLength(body.contents, "utf8") > MAX_SCRIPT_BYTES) {
            sendJson(response, 400, { error: "Lua scripts must be 1 MB or smaller." });
            return;
        }

        const scriptPath = path.resolve(ROOT, ...scriptSource.split("/"));
        if (!isInside(path.join(ROOT, "computercraft"), scriptPath)) {
            sendJson(response, 400, { error: "Invalid ComputerCraft script path." });
            return;
        }
        const catalog = await readCatalog();
        const catalogIndex = catalog.findIndex((entry) => entry.source === scriptSource);
        if (catalogIndex === -1 && body.contents === undefined) {
            sendJson(response, 400, { error: "Upload a Lua script when setting the first version." });
            return;
        }
        if (body.contents !== undefined) await writeAtomically(scriptPath, body.contents);

        if (catalogIndex >= 0) {
            catalog[catalogIndex].version = body.version;
            await writeCatalog(catalog);
        } else {
            const versions = await readScriptVersions();
            versions[scriptSource] = body.version;
            await writeAtomically(SCRIPT_VERSIONS_PATH, `${JSON.stringify(versions, null, 2)}\n`);
        }
        sendJson(response, 200, { source: scriptSource, version: body.version });
        return;
    }

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

cleanupExpiredShares().catch((error) => console.error("Could not clean up expired shared files:", error));
const shareCleanupTimer = setInterval(() => {
    cleanupExpiredShares().catch((error) => console.error("Could not clean up expired shared files:", error));
}, 15 * 60 * 1000);
shareCleanupTimer.unref();

server.listen(PORT, HOST, () => {
    console.log(`Rift Script Library listening on http://${HOST}:${PORT}`);
});