// Org Guard: guarded deploy/retrieve for per-customer package directories.
//
// A path under customers/<name>/ may only be deployed to / retrieved from the
// org mapped to <name> in customers/customers.json. On a mismatch the action
// is blocked; on a match an explicit modal confirmation is still required.
const vscode = require("vscode");
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

let statusItem;

function findProjectRoot() {
  for (const folder of vscode.workspace.workspaceFolders || []) {
    if (fs.existsSync(path.join(folder.uri.fsPath, "sfdx-project.json"))) {
      return folder.uri.fsPath;
    }
  }
  return undefined;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return undefined;
  }
}

function readCustomerMap(root) {
  return readJson(path.join(root, "customers", "customers.json")) || {};
}

function readTargetOrg(root) {
  const config = readJson(path.join(root, ".sf", "config.json")) || {};
  return config["target-org"];
}

// alias -> username, from the CLI's local alias store (no network call).
function readAliases(root) {
  return new Promise((resolve) => {
    execFile(
      "sf",
      ["alias", "list", "--json"],
      { cwd: root, shell: true },
      (err, stdout) => {
        const map = {};
        try {
          for (const row of JSON.parse(stdout).result || []) {
            map[row.alias] = row.value;
          }
        } catch {
          // fall through with an empty map; comparison falls back to raw strings
        }
        resolve(map);
      }
    );
  });
}

function toUsername(aliases, orgOrAlias) {
  return aliases[orgOrAlias] || orgOrAlias;
}

// Returns the customer folder name for a path, or undefined if it is not in one.
function customerOf(root, fsPath) {
  const rel = path.relative(root, fsPath).split(path.sep);
  if (
    rel[0] === "customers" &&
    rel.length >= 2 &&
    rel[1] !== "customers.json"
  ) {
    return rel[1];
  }
  return undefined;
}

function selectedPaths(uri, uris) {
  if (Array.isArray(uris) && uris.length > 0) {
    return uris.map((u) => u.fsPath);
  }
  if (uri && uri.fsPath) {
    return [uri.fsPath];
  }
  const editor = vscode.window.activeTextEditor;
  return editor ? [editor.document.uri.fsPath] : [];
}

async function switchCustomer(root, customer) {
  const map = readCustomerMap(root);
  if (!customer) {
    customer = await vscode.window
      .showQuickPick(
        Object.keys(map).map((c) => ({ label: c, description: map[c] })),
        { placeHolder: "Select the customer to work on" }
      )
      .then((pick) => pick && pick.label);
    if (!customer) {
      return false;
    }
  }
  const org = map[customer];
  await new Promise((resolve, reject) => {
    execFile(
      "sf",
      ["config", "set", `target-org="${org}"`],
      { cwd: root, shell: true },
      (err) => (err ? reject(err) : resolve())
    );
  }).catch((err) => {
    vscode.window.showErrorMessage(
      `Org Guard: could not set default org: ${err.message}`
    );
    throw err;
  });
  await refreshStatus();
  return true;
}

async function guard(action, uri, uris) {
  const root = findProjectRoot();
  if (!root) {
    vscode.window.showErrorMessage(
      "Org Guard: no sfdx-project.json in this workspace."
    );
    return;
  }
  const paths = selectedPaths(uri, uris);
  if (paths.length === 0) {
    vscode.window.showErrorMessage("Org Guard: nothing selected.");
    return;
  }

  const customers = new Set(paths.map((p) => customerOf(root, p)));
  if (customers.has(undefined)) {
    vscode.window.showErrorMessage(
      `Org Guard: BLOCKED. Only paths inside customers/<name>/ can be ${action === "deploy" ? "deployed" : "retrieved"}. ` +
        "Move the files into the right customer folder first.",
      { modal: true }
    );
    return;
  }
  if (customers.size > 1) {
    vscode.window.showErrorMessage(
      `Org Guard: BLOCKED. The selection spans several customers (${[...customers].join(", ")}). Select one customer at a time.`,
      { modal: true }
    );
    return;
  }

  const customer = [...customers][0];
  const map = readCustomerMap(root);
  const expectedOrg = map[customer];
  if (!expectedOrg) {
    vscode.window.showErrorMessage(
      `Org Guard: BLOCKED. customers/${customer} has no org mapping in customers/customers.json.`,
      { modal: true }
    );
    return;
  }

  const aliases = await readAliases(root);
  let currentOrg = readTargetOrg(root);
  if (
    !currentOrg ||
    toUsername(aliases, currentOrg) !== toUsername(aliases, expectedOrg)
  ) {
    const switchLabel = `Switch to "${expectedOrg}"`;
    const choice = await vscode.window.showErrorMessage(
      "Org Guard: BLOCKED — ORG MISMATCH",
      {
        modal: true,
        detail:
          `Folder: customers/${customer}\n` +
          `Belongs to: ${expectedOrg}\n` +
          `Current default org: ${currentOrg || "(none)"}`
      },
      switchLabel
    );
    if (choice !== switchLabel) {
      return;
    }
    try {
      await switchCustomer(root, customer);
    } catch {
      return;
    }
    currentOrg = readTargetOrg(root);
  }

  const verb = action === "deploy" ? "DEPLOY" : "RETRIEVE";
  const direction = action === "deploy" ? "to" : "from";
  const rels = paths.map((p) =>
    path.relative(root, p).split(path.sep).join("/")
  );
  const isProd = /prod/i.test(expectedOrg);
  const ok = await vscode.window.showWarningMessage(
    `${isProd ? "⚠ PRODUCTION ORG — " : ""}${verb} ${direction} "${expectedOrg}"?`,
    {
      modal: true,
      detail:
        `Org: ${expectedOrg} (${toUsername(aliases, expectedOrg)})\n` +
        `Customer folder: customers/${customer}\n\n` +
        rels.join("\n") +
        (action === "retrieve"
          ? "\n\nLocal files will be overwritten with the org version."
          : "")
    },
    `${verb} ${direction} ${expectedOrg}`
  );
  if (!ok) {
    return;
  }

  // Pass --target-org explicitly so the command cannot pick up a different default later.
  const sourceArgs = rels.map((r) => `--source-dir "${r}"`).join(" ");
  const cmd = `sf project ${action} start ${sourceArgs} --target-org "${expectedOrg}"`;
  const terminal =
    vscode.window.terminals.find((t) => t.name === "Org Guard") ||
    vscode.window.createTerminal({ name: "Org Guard", cwd: root });
  terminal.show(true);
  terminal.sendText(cmd);
}

async function refreshStatus() {
  const root = findProjectRoot();
  if (!root || !statusItem) {
    return;
  }
  const org = readTargetOrg(root) || "(none)";
  const map = readCustomerMap(root);
  const aliases = await readAliases(root);
  const customer = Object.keys(map).find(
    (c) => toUsername(aliases, map[c]) === toUsername(aliases, org)
  );
  statusItem.text = `$(shield) ${customer || "no customer"} → ${org}`;
  statusItem.tooltip =
    "Org Guard: current customer / default org. Click to switch.";
  statusItem.backgroundColor = /prod/i.test(org)
    ? new vscode.ThemeColor("statusBarItem.errorBackground")
    : undefined;
  statusItem.show();
}

// ---------- Auto-sort: move retrieves that land in force-app into the customer folder ----------
// Org Browser (and any retrieve of a component not yet in the project) writes to the
// default package directory, force-app. Once the burst of writes settles, everything
// there is moved into customers/<customer>/ for the current default org.

const LANDING_DIR = "force-app";
let sortTimer;

function listFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFiles(full));
    } else if (entry.name !== ".gitkeep") {
      out.push(full);
    }
  }
  return out;
}

function removeEmptyDirs(dir, keep) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      removeEmptyDirs(path.join(dir, entry.name), false);
    }
  }
  if (!keep && fs.readdirSync(dir).length === 0) {
    fs.rmdirSync(dir);
  }
}

function moveFile(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  try {
    fs.renameSync(src, dest);
  } catch {
    // OneDrive / editor locks can refuse a rename; copy + delete instead.
    fs.copyFileSync(src, dest);
    fs.unlinkSync(src);
  }
}

function scheduleSort() {
  if (
    !vscode.workspace
      .getConfiguration("orgGuard")
      .get("autoSortRetrieves", true)
  ) {
    return;
  }
  clearTimeout(sortTimer);
  sortTimer = setTimeout(
    () =>
      sortLanding().catch((err) => {
        vscode.window.showErrorMessage(
          `Org Guard: auto-sort failed: ${err.message}`
        );
      }),
    2000
  );
}

async function sortLanding() {
  const root = findProjectRoot();
  if (!root) {
    return;
  }
  const landing = path.join(root, LANDING_DIR);
  if (!fs.existsSync(landing)) {
    return;
  }
  const files = listFiles(landing);
  if (files.length === 0) {
    return;
  }

  const org = readTargetOrg(root);
  const map = readCustomerMap(root);
  const aliases = await readAliases(root);
  const customer = Object.keys(map).find(
    (c) => toUsername(aliases, map[c]) === toUsername(aliases, org)
  );
  if (!customer) {
    vscode.window.showWarningMessage(
      `Org Guard: ${files.length} file(s) were retrieved into ${LANDING_DIR}, but the default org ` +
        `"${org || "(none)"}" is not mapped in customers/customers.json. They were left in ${LANDING_DIR}.`
    );
    return;
  }

  const target = path.join(root, "customers", customer);
  const moved = [];
  const conflicts = [];
  for (const file of files) {
    const dest = path.join(target, path.relative(landing, file));
    if (fs.existsSync(dest)) {
      conflicts.push(path.relative(root, file).split(path.sep).join("/"));
      continue;
    }
    moveFile(file, dest);
    moved.push(dest);
  }
  removeEmptyDirs(landing, true);

  if (moved.length > 0) {
    vscode.window.showInformationMessage(
      `Org Guard: moved ${moved.length} retrieved file(s) from "${org}" into customers/${customer}.`
    );
  }
  if (conflicts.length > 0) {
    vscode.window.showWarningMessage(
      `Org Guard: ${conflicts.length} file(s) already exist in customers/${customer} and were left in ` +
        `${LANDING_DIR} for you to compare: ${conflicts.slice(0, 5).join(", ")}${conflicts.length > 5 ? ", …" : ""}`
    );
  }
}

function activate(context) {
  statusItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    100
  );
  statusItem.command = "orgGuard.switchCustomer";
  context.subscriptions.push(statusItem);

  context.subscriptions.push(
    vscode.commands.registerCommand("orgGuard.deploy", (uri, uris) =>
      guard("deploy", uri, uris)
    ),
    vscode.commands.registerCommand("orgGuard.retrieve", (uri, uris) =>
      guard("retrieve", uri, uris)
    ),
    vscode.commands.registerCommand("orgGuard.switchCustomer", async () => {
      const root = findProjectRoot();
      if (root) {
        await switchCustomer(root).catch(() => undefined);
      }
    })
  );

  // Keep the status bar in sync when the org is changed elsewhere (CLI, SFDX status bar picker).
  const root = findProjectRoot();
  if (root) {
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(
        root,
        "{.sf/config.json,customers/customers.json}"
      )
    );
    watcher.onDidChange(refreshStatus);
    watcher.onDidCreate(refreshStatus);
    context.subscriptions.push(watcher);

    const landingWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(root, `${LANDING_DIR}/**`)
    );
    landingWatcher.onDidCreate(scheduleSort);
    landingWatcher.onDidChange(scheduleSort);
    context.subscriptions.push(landingWatcher);
    scheduleSort();
  }
  refreshStatus();
}

function deactivate() {}

module.exports = { activate, deactivate };
